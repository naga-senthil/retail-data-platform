#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BATCH_ID="${1:?Usage: load_file.sh <YYYYMMDD> <dataset_key>}"
DATASET="${2:?Usage: load_file.sh <YYYYMMDD> <dataset_key>}"

TABLE_NAME="$(printf '%s' "$DATASET" | tr '[:lower:]' '[:upper:]')"
FILE_NAME="${DATASET}.csv"
STAGE_PATH="daily/batch_${BATCH_ID}/${FILE_NAME}"
LOCAL_FILE="${DAILY_BATCH_DIR}/batch_${BATCH_ID}/${FILE_NAME}"
ERROR_FILE="${REJECTED_DATA_DIR}/${DATASET}_${BATCH_ID}_errors.csv"
RUN_TOKEN="${BATCH_ID}_${DATASET}_$(date '+%Y%m%d%H%M%S')_$$"

STATUS_LOG="${LOG_DIR}/load_status_${RUN_TOKEN}.log"
COPY_LOG="${LOG_DIR}/copy_${RUN_TOKEN}.log"
COPY_STDERR_LOG="${LOG_DIR}/copy_stderr_${RUN_TOKEN}.log"
REJECT_LOG="${LOG_DIR}/rejected_export_${RUN_TOKEN}.log"

CURRENT_OPERATION="input validation"
ROWS_PARSED=0
ROWS_LOADED=0
ROWS_SKIPPED=0
ERROR_COUNT=0

# Define the source columns and CSV positional fields for each supported dataset.
# Keep these in the same order as the corresponding CSV headers.
case "$DATASET" in
    orders)
        SOURCE_COLUMN_LIST="ORDER_ID,CUSTOMER_ID,ORDER_STATUS,ORDER_PURCHASE_TIMESTAMP,ORDER_APPROVED_AT,ORDER_DELIVERED_CARRIER_DATE,ORDER_DELIVERED_CUSTOMER_DATE,ORDER_ESTIMATED_DELIVERY_DATE"
        SOURCE_FIELD_LIST='$1,$2,$3,$4,$5,$6,$7,$8'
        ;;
    order_items)
        SOURCE_COLUMN_LIST="ORDER_ID,ORDER_ITEM_ID,PRODUCT_ID,SELLER_ID,SHIPPING_LIMIT_DATE,PRICE,FREIGHT_VALUE"
        SOURCE_FIELD_LIST='$1,$2,$3,$4,$5,$6,$7'
        ;;
    order_payments)
        SOURCE_COLUMN_LIST="ORDER_ID,PAYMENT_SEQUENTIAL,PAYMENT_TYPE,PAYMENT_INSTALLMENTS,PAYMENT_VALUE"
        SOURCE_FIELD_LIST='$1,$2,$3,$4,$5'
        ;;
    order_reviews)
        SOURCE_COLUMN_LIST="REVIEW_ID,ORDER_ID,REVIEW_SCORE,REVIEW_COMMENT_TITLE,REVIEW_COMMENT_MESSAGE,REVIEW_CREATION_DATE,REVIEW_ANSWER_TIMESTAMP"
        SOURCE_FIELD_LIST='$1,$2,$3,$4,$5,$6,$7'
        ;;
    *)
        fail_load "Unsupported daily dataset '${DATASET}'."
        ;;
esac

# -----------------------------------------------------------------------------
# Step 1 - Validate input
# -----------------------------------------------------------------------------

info "Step 1 - Validate input"
info "Validating batch ${BATCH_ID} and dataset ${DATASET}."

[[ "$BATCH_ID" =~ ^[0-9]{8}$ ]] ||
    fail_load "Invalid batch ID '${BATCH_ID}'; expected YYYYMMDD."

[[ -f "$LOCAL_FILE" ]] ||
    fail_load "Source CSV not found: ${LOCAL_FILE}"

for command_name in snow awk grep tr tail; do
    require_command "$command_name" ||
        fail_load "Required command is unavailable: ${command_name}"
done

success "Input validated; target table is ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${TABLE_NAME}."
info "Run token: ${RUN_TOKEN}"

# -----------------------------------------------------------------------------
# Step 2 - Check whether this file needs loading
# -----------------------------------------------------------------------------

CURRENT_OPERATION="checking previous load status"
info "Step 2 - Check load status"
info "Checking load history for ${STAGE_PATH}."

if LOADED_FLAG="$(sql_scalar \
    -D FILE_PATH="$STAGE_PATH" \
    -D TARGET_TABLE="$TABLE_NAME" \
    -f "$CHECK_LOAD_STATUS_SQL" 2>"$STATUS_LOG")"; then
    LOADED_FLAG="$(printf '%s' "$LOADED_FLAG" | tr -d '[:space:]')"
else
    error "Could not query load history. Details: ${STATUS_LOG}"
    show_log_tail "$STATUS_LOG"
    fail_load "Load-status query failed for ${STAGE_PATH}."
fi

if [[ "$LOADED_FLAG" == "1" ]]; then
    info "File was already loaded successfully; duplicate file load skipped."
    send_mail \
        "[RETAIL DW] LOAD SKIPPED - ${TABLE_NAME}" \
        "Status: SKIPPED\nBatch: ${BATCH_ID}\nDataset: ${TABLE_NAME}\nFile: ${STAGE_PATH}\nReason: File was already loaded successfully.\nRun token: ${RUN_TOKEN}"
    success "Load skipped: batch=${BATCH_ID}, dataset=${DATASET}."
    exit 0
fi

if [[ "$LOADED_FLAG" != "0" ]]; then
    fail_load "Unexpected load-status value '${LOADED_FLAG}' for ${STAGE_PATH}."
fi

info "Counting data rows in ${LOCAL_FILE}."
ROW_COUNT="$(awk 'NR > 1 { n++ } END { print n+0 }' "$LOCAL_FILE")"
info "Source data rows: ${ROW_COUNT}."

if (( ROW_COUNT == 0 )); then
    CURRENT_OPERATION="auditing empty source file"
    info "CSV contains no data rows; recording SKIPPED status."

    audit_start "$BATCH_ID" "$STAGE_PATH" "$TABLE_NAME" "$RUN_TOKEN" ||
        fail_load "Could not create audit record for empty CSV."
    LOAD_AUDIT_STARTED=1

    audit_update \
        "$RUN_TOKEN" \
        "SKIPPED" \
        0 0 0 0 \
        "CSV contains no data rows" ||
        fail_load "Could not mark empty CSV as SKIPPED."
    LOAD_AUDIT_STARTED=0

    send_mail \
        "[RETAIL DW] CSV SKIPPED - ${TABLE_NAME}" \
        "Status: SKIPPED\nBatch: ${BATCH_ID}\nDataset: ${TABLE_NAME}\nFile: ${STAGE_PATH}\nReason: CSV contains no data rows.\nRun token: ${RUN_TOKEN}"
    success "Empty CSV audited as SKIPPED: ${STAGE_PATH}."
    exit 0
fi

# -----------------------------------------------------------------------------
# Step 3 - Append data into permanent Bronze
# -----------------------------------------------------------------------------

CURRENT_OPERATION="creating load audit record"
info "Step 3 - Append data into Bronze"
info "Creating RUNNING audit record for ${STAGE_PATH}."

audit_start "$BATCH_ID" "$STAGE_PATH" "$TABLE_NAME" "$RUN_TOKEN" ||
    fail_load "Could not create load audit record."
LOAD_AUDIT_STARTED=1
success "Load audit started."

# Do not truncate Bronze. Bronze is the persistent raw-data layer.
# The COPY template appends source columns plus LOAD_BATCH_ID and INGESTED_AT.
CURRENT_OPERATION="executing COPY INTO"
info "Appending ${STAGE_PATH} into ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${TABLE_NAME}."

if COPY_OUTPUT="$(snow_sql \
    --format TABLE \
    --silent \
    -D TABLE_NAME="$TABLE_NAME" \
    -D STAGE_PATH="$STAGE_PATH" \
    -D FILE_FORMAT="$SNOWFLAKE_FILE_FORMAT" \
    -D BATCH_ID="$BATCH_ID" \
    -D SOURCE_COLUMN_LIST="$SOURCE_COLUMN_LIST" \
    -D SOURCE_FIELD_LIST="$SOURCE_FIELD_LIST" \
    -f "$COPY_INTO_BRONZE_SQL" 2>"$COPY_STDERR_LOG")"; then
    printf '%s\n' "$COPY_OUTPUT" > "$COPY_LOG"
    if [[ -s "$COPY_STDERR_LOG" ]]; then
        cat "$COPY_STDERR_LOG" >> "$COPY_LOG"
    fi
    success "COPY INTO command completed. Output: ${COPY_LOG}"
else
    {
        printf '%s\n' "${COPY_OUTPUT:-}"
        [[ -s "$COPY_STDERR_LOG" ]] && cat "$COPY_STDERR_LOG"
    } > "$COPY_LOG"
    error "COPY INTO failed. Details: ${COPY_LOG}"
    show_log_tail "$COPY_LOG"
    fail_load "Snowflake COPY INTO failed for ${STAGE_PATH}."
fi

CURRENT_OPERATION="extracting COPY query ID"
QUERY_ID="$(printf '%s\n' "$COPY_OUTPUT" |
    grep -Eo '[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}' |
    tail -n 1 || true)"

[[ -n "$QUERY_ID" ]] || {
    error "COPY query ID was not found. COPY output: ${COPY_LOG}"
    show_log_tail "$COPY_LOG"
    fail_load "Could not identify the COPY query ID."
}

info "COPY query ID: ${QUERY_ID}."

CURRENT_OPERATION="reading COPY statistics"
COUNTS="$(printf '%s\n' "$COPY_OUTPUT" | awk -F'|' '
    {
        status = $3
        parsed = $4
        loaded = $5
        errors = $7

        gsub(/[[:space:]]/, "", status)
        gsub(/[[:space:]]/, "", parsed)
        gsub(/[[:space:]]/, "", loaded)
        gsub(/[[:space:]]/, "", errors)

        if ((status == "LOADED" || status == "PARTIALLY_LOADED" || status == "LOAD_SKIPPED") &&
            parsed ~ /^[0-9]+$/ && loaded ~ /^[0-9]+$/ && errors ~ /^[0-9]+$/) {
            print parsed, loaded, errors
            exit
        }
    }')"

[[ -n "$COUNTS" ]] || {
    error "Could not parse COPY statistics. COPY output: ${COPY_LOG}"
    show_log_tail "$COPY_LOG"
    fail_load "Could not extract parsed, loaded, and error counts from COPY output."
}

read -r ROWS_PARSED ROWS_LOADED ERROR_COUNT <<< "$COUNTS"
ROWS_SKIPPED=$((ROWS_PARSED - ROWS_LOADED))
(( ROWS_SKIPPED >= 0 )) || fail_load "COPY statistics are inconsistent: loaded rows exceed parsed rows."

success "COPY statistics: parsed=${ROWS_PARSED}, loaded=${ROWS_LOADED}, skipped=${ROWS_SKIPPED}, errors=${ERROR_COUNT}."

# -----------------------------------------------------------------------------
# Step 4 - Record results and notify
# -----------------------------------------------------------------------------

if (( ROWS_SKIPPED > 0 || ERROR_COUNT > 0 )); then
    CURRENT_OPERATION="exporting rejected rows"
    info "Step 4 - Record partial load result"
    info "Exporting COPY errors to ${ERROR_FILE}."

    if snow_sql \
        --format CSV \
        --silent \
        -D TABLE_NAME="$TABLE_NAME" \
        -D QUERY_ID="$QUERY_ID" \
        -f "$VALIDATE_COPY_ERRORS_SQL" >"$ERROR_FILE" 2>"$REJECT_LOG"; then
        success "Rejected-row export completed: ${ERROR_FILE}."
    else
        error "Rejected-row export failed. Details: ${REJECT_LOG}"
        show_log_tail "$REJECT_LOG"
        fail_load "Could not export rejected rows for query ${QUERY_ID}."
    fi

    CURRENT_OPERATION="updating partial-success audit status"
    audit_update \
        "$RUN_TOKEN" \
        "PARTIAL_SUCCESS" \
        "$ROWS_PARSED" \
        "$ROWS_LOADED" \
        "$ROWS_SKIPPED" \
        "$ERROR_COUNT" \
        "Rejected rows present; see ${ERROR_FILE}" ||
        fail_load "Could not update audit status to PARTIAL_SUCCESS."
    LOAD_AUDIT_STARTED=0

    send_mail \
        "[RETAIL DW] PARTIAL SUCCESS - ${TABLE_NAME}" \
        "Status: PARTIAL_SUCCESS\nBatch: ${BATCH_ID}\nDataset: ${TABLE_NAME}\nFile: ${STAGE_PATH}\nRows parsed: ${ROWS_PARSED}\nRows loaded: ${ROWS_LOADED}\nRows skipped: ${ROWS_SKIPPED}\nErrors: ${ERROR_COUNT}\nRejected rows: ${ERROR_FILE}\nCOPY query ID: ${QUERY_ID}\nRun token: ${RUN_TOKEN}"

    warn "Load finished with rejected or skipped records; review ${ERROR_FILE}."
    success "Batch processing finished: batch=${BATCH_ID}, dataset=${DATASET}, status=PARTIAL_SUCCESS."
    exit 0
fi

CURRENT_OPERATION="updating successful load audit status"
info "Step 4 - Record successful load"

audit_update \
    "$RUN_TOKEN" \
    "SUCCESS" \
    "$ROWS_PARSED" \
    "$ROWS_LOADED" \
    0 \
    0 \
    "" ||
    fail_load "Could not update audit status to SUCCESS."
LOAD_AUDIT_STARTED=0

success "Load audit status set to SUCCESS."

send_mail \
    "[RETAIL DW] SUCCESS - ${TABLE_NAME}" \
    "Status: SUCCESS\nBatch: ${BATCH_ID}\nDataset: ${TABLE_NAME}\nFile: ${STAGE_PATH}\nRows parsed: ${ROWS_PARSED}\nRows loaded: ${ROWS_LOADED}\nCOPY query ID: ${QUERY_ID}\nRun token: ${RUN_TOKEN}"

success "Load completed: batch=${BATCH_ID}, dataset=${DATASET}, table=${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${TABLE_NAME}, rows_loaded=${ROWS_LOADED}."
