
#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BATCH_ID="REFERENCE"
DATASET="${1:?Usage: load_reference.sh <dataset>}"

TABLE_NAME="$(printf '%s' "$DATASET" | tr '[:lower:]' '[:upper:]')"
FILE_NAME="${DATASET}.csv"
STAGE_PATH="reference/${FILE_NAME}"
LOCAL_FILE="${REFERENCE_DATA_DIR}/${FILE_NAME}"

RUN_TOKEN="REFERENCE_${DATASET}_$(date '+%Y%m%d%H%M%S')_$$"

STATUS_LOG="${LOG_DIR}/load_status_${RUN_TOKEN}.log"
COPY_LOG="${LOG_DIR}/copy_${RUN_TOKEN}.log"
COPY_STDERR_LOG="${LOG_DIR}/copy_stderr_${RUN_TOKEN}.log"

ROWS_PARSED=0
ROWS_LOADED=0
ROWS_SKIPPED=0
ERROR_COUNT=0

CURRENT_OPERATION="validating reference dataset"

# -----------------------------------------------------------------------------
# Source column mappings
# -----------------------------------------------------------------------------

case "$DATASET" in
    customers)
        SOURCE_COLUMN_LIST="CUSTOMER_ID,CUSTOMER_UNIQUE_ID,CUSTOMER_ZIP_CODE_PREFIX,CUSTOMER_CITY,CUSTOMER_STATE"
        SOURCE_FIELD_LIST='$1,$2,$3,$4,$5'
        ;;
    products)
        SOURCE_COLUMN_LIST="PRODUCT_ID,PRODUCT_CATEGORY_NAME,PRODUCT_NAME_LENGHT,PRODUCT_DESCRIPTION_LENGHT,PRODUCT_PHOTOS_QTY,PRODUCT_WEIGHT_G,PRODUCT_LENGTH_CM,PRODUCT_HEIGHT_CM,PRODUCT_WIDTH_CM"
        SOURCE_FIELD_LIST='$1,$2,$3,$4,$5,$6,$7,$8,$9'
        ;;
    sellers)
        SOURCE_COLUMN_LIST="SELLER_ID,SELLER_ZIP_CODE_PREFIX,SELLER_CITY,SELLER_STATE"
        SOURCE_FIELD_LIST='$1,$2,$3,$4'
        ;;
    geolocation)
        SOURCE_COLUMN_LIST="GEOLOCATION_ZIP_CODE_PREFIX,GEOLOCATION_LAT,GEOLOCATION_LNG,GEOLOCATION_CITY,GEOLOCATION_STATE"
        SOURCE_FIELD_LIST='$1,$2,$3,$4,$5'
        ;;
    category_translation)
        SOURCE_COLUMN_LIST="PRODUCT_CATEGORY_NAME,PRODUCT_CATEGORY_NAME_ENGLISH"
        SOURCE_FIELD_LIST='$1,$2'
        ;;
    *)
        fail_load "Unsupported reference dataset: ${DATASET}"
        ;;
esac

# -----------------------------------------------------------------------------
# Step 1 - Validate input
# -----------------------------------------------------------------------------

info "Step 1 - Validate input"
info "Dataset: ${DATASET}"
info "Batch ID: ${BATCH_ID}"

[[ -f "$LOCAL_FILE" ]] ||
    fail_load "Reference CSV not found: ${LOCAL_FILE}"

success "Input validated."
info "Target table: ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${TABLE_NAME}"
info "Stage path: ${STAGE_PATH}"
info "File format: ${SNOWFLAKE_FILE_FORMAT}"
info "Run token: ${RUN_TOKEN}"

# -----------------------------------------------------------------------------
# Step 2 - Check previous successful load
# -----------------------------------------------------------------------------

CURRENT_OPERATION="checking previous load status"

info "Step 2 - Check load status"
info "Checking load history for ${STAGE_PATH}."

if LOADED_FLAG="$(sql_scalar \
    -D FILE_PATH="$STAGE_PATH" \
    -D TARGET_TABLE="$TABLE_NAME" \
    -f "$CHECK_LOAD_STATUS_SQL" \
    2>"$STATUS_LOG")"; then

    LOADED_FLAG="$(printf '%s' "$LOADED_FLAG" | tr -d '[:space:]')"

else
    error "Load-status query failed. Details: ${STATUS_LOG}"
    show_log_tail "$STATUS_LOG"
    fail_load "Could not check load history for ${STAGE_PATH}"
fi

info "Load-status query returned: '${LOADED_FLAG}'."

if [[ "$LOADED_FLAG" == "1" ]]; then

    info "Reference file was already loaded successfully."
    info "Skipping duplicate file load: ${STAGE_PATH}"

    send_mail \
        "[RETAIL DW] LOAD SKIPPED - ${TABLE_NAME}" \
        "Status: SKIPPED
Batch: ${BATCH_ID}
Dataset: ${TABLE_NAME}
File: ${STAGE_PATH}
Reason: File was already loaded successfully.
Run token: ${RUN_TOKEN}"

    success "Load skipped: ${DATASET}"
    exit 0
fi

[[ "$LOADED_FLAG" == "0" ]] ||
    fail_load "Unexpected load-status value '${LOADED_FLAG}'"

# -----------------------------------------------------------------------------
# Step 3 - Check source row count
# -----------------------------------------------------------------------------

CURRENT_OPERATION="checking source row count"

info "Step 3 - Check source row count"
info "Counting rows; excluding the CSV header."

ROW_COUNT="$(awk 'NR > 1 { n++ } END { print n+0 }' "$LOCAL_FILE")"

info "Source data rows: ${ROW_COUNT}"

if (( ROW_COUNT == 0 )); then

    CURRENT_OPERATION="auditing empty reference file"

    info "CSV contains no data rows."
    info "Recording audit status SKIPPED."

    audit_start \
        "$BATCH_ID" \
        "$STAGE_PATH" \
        "$TABLE_NAME" \
        "$RUN_TOKEN" ||
        fail_load "Could not create audit record for empty CSV"

    LOAD_AUDIT_STARTED=1

    audit_update \
        "$RUN_TOKEN" \
        "SKIPPED" \
        0 0 0 0 \
        "Reference CSV contains no data rows" ||
        fail_load "Could not update empty-file audit record"

    LOAD_AUDIT_STARTED=0

    send_mail \
        "[RETAIL DW] CSV SKIPPED - ${TABLE_NAME}" \
        "Status: SKIPPED
Batch: ${BATCH_ID}
Dataset: ${TABLE_NAME}
File: ${STAGE_PATH}
Reason: Reference CSV contains no data rows.
Run token: ${RUN_TOKEN}"

    success "Empty reference CSV audited as SKIPPED."
    exit 0
fi

# -----------------------------------------------------------------------------
# Step 4 - Start load audit
# -----------------------------------------------------------------------------

CURRENT_OPERATION="creating load audit record"

info "Step 4 - Start load audit"
info "Creating RUNNING audit record."

audit_start \
    "$BATCH_ID" \
    "$STAGE_PATH" \
    "$TABLE_NAME" \
    "$RUN_TOKEN" ||
    fail_load "Could not create load audit record"

LOAD_AUDIT_STARTED=1

success "Load audit started."

# -----------------------------------------------------------------------------
# Step 5 - Append into Bronze
# -----------------------------------------------------------------------------

CURRENT_OPERATION="executing COPY INTO"

info "Step 5 - Append data into Bronze"
info "Target: ${SNOWFLAKE_DATABASE}.${SNOWFLAKE_SCHEMA}.${TABLE_NAME}"
info "Stage path: ${STAGE_PATH}"

if COPY_OUTPUT="$(snow_sql \
    --format TABLE \
    --silent \
    -D TABLE_NAME="$TABLE_NAME" \
    -D STAGE_PATH="$STAGE_PATH" \
    -D FILE_FORMAT="$SNOWFLAKE_FILE_FORMAT" \
    -D BATCH_ID="$BATCH_ID" \
    -D SOURCE_COLUMN_LIST="$SOURCE_COLUMN_LIST" \
    -D SOURCE_FIELD_LIST="$SOURCE_FIELD_LIST" \
    -f "$COPY_INTO_BRONZE_SQL" \
    2>"$COPY_STDERR_LOG")"; then

    printf '%s\n' "$COPY_OUTPUT" > "$COPY_LOG"

    if [[ -s "$COPY_STDERR_LOG" ]]; then
        cat "$COPY_STDERR_LOG" >> "$COPY_LOG"
    fi

    success "COPY INTO completed. Details: ${COPY_LOG}"

else
    {
        printf '%s\n' "${COPY_OUTPUT:-}"
        [[ -s "$COPY_STDERR_LOG" ]] && cat "$COPY_STDERR_LOG"
    } > "$COPY_LOG"

    error "COPY INTO failed. Details: ${COPY_LOG}"
    show_log_tail "$COPY_LOG"
    fail_load "Snowflake COPY INTO failed for ${STAGE_PATH}"
fi

# -----------------------------------------------------------------------------
# Step 6 - Extract COPY query ID and statistics
# -----------------------------------------------------------------------------

CURRENT_OPERATION="extracting COPY query ID"

info "Step 6 - Extract COPY query ID"

QUERY_ID="$(printf '%s\n' "$COPY_OUTPUT" |
    grep -Eo '[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}' |
    tail -n 1 || true)"

[[ -n "$QUERY_ID" ]] || {
    error "COPY query ID was not found. Details: ${COPY_LOG}"
    show_log_tail "$COPY_LOG"
    fail_load "Could not identify the COPY query ID"
}

info "COPY query ID: ${QUERY_ID}"

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
    error "Could not parse COPY statistics. Details: ${COPY_LOG}"
    show_log_tail "$COPY_LOG"
    fail_load "Could not extract COPY row counts"
}

read -r ROWS_PARSED ROWS_LOADED ERROR_COUNT <<< "$COUNTS"

ROWS_SKIPPED=$((ROWS_PARSED - ROWS_LOADED))

(( ROWS_SKIPPED >= 0 )) ||
    fail_load "COPY statistics are inconsistent"

success "Rows parsed: ${ROWS_PARSED}"
success "Rows loaded: ${ROWS_LOADED}"
info "Rows skipped: ${ROWS_SKIPPED}"
info "Errors: ${ERROR_COUNT}"

# -----------------------------------------------------------------------------
# Step 7 - Update load audit
# -----------------------------------------------------------------------------

if (( ROWS_SKIPPED > 0 || ERROR_COUNT > 0 )); then

    CURRENT_OPERATION="updating partial-success audit status"

    warn "COPY reported skipped or rejected rows."

    audit_update \
        "$RUN_TOKEN" \
        "PARTIAL_SUCCESS" \
        "$ROWS_PARSED" \
        "$ROWS_LOADED" \
        "$ROWS_SKIPPED" \
        "$ERROR_COUNT" \
        "COPY reported skipped or rejected rows" ||
        fail_load "Could not update audit status to PARTIAL_SUCCESS"

    LOAD_AUDIT_STARTED=0

    send_mail \
        "[RETAIL DW] PARTIAL SUCCESS - ${TABLE_NAME}" \
        "Status: PARTIAL_SUCCESS
Batch: ${BATCH_ID}
Dataset: ${TABLE_NAME}
File: ${STAGE_PATH}
Rows parsed: ${ROWS_PARSED}
Rows loaded: ${ROWS_LOADED}
Rows skipped: ${ROWS_SKIPPED}
Errors: ${ERROR_COUNT}
COPY query ID: ${QUERY_ID}
Run token: ${RUN_TOKEN}"

    warn "Reference load finished with rejected or skipped rows."
    exit 0
fi

CURRENT_OPERATION="updating successful load audit status"

info "Updating audit status to SUCCESS."

audit_update \
    "$RUN_TOKEN" \
    "SUCCESS" \
    "$ROWS_PARSED" \
    "$ROWS_LOADED" \
    0 \
    0 \
    "" ||
    fail_load "Could not update audit status to SUCCESS"

LOAD_AUDIT_STARTED=0

success "Load audit status set to SUCCESS."

send_mail \
    "[RETAIL DW] SUCCESS - ${TABLE_NAME}" \
    "Status: SUCCESS
Batch: ${BATCH_ID}
Dataset: ${TABLE_NAME}
File: ${STAGE_PATH}
Rows parsed: ${ROWS_PARSED}
Rows loaded: ${ROWS_LOADED}
COPY query ID: ${QUERY_ID}
Run token: ${RUN_TOKEN}"

success "Reference load completed: ${TABLE_NAME}"
