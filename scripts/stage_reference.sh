#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

BATCH_ID="REFERENCE"
DATASET="${1:?Usage: stage_reference.sh <dataset_key>}"
REFERENCE_DATA_DIR="${REFERENCE_DATA_DIR:-data/batches/reference}"

FILE_NAME="${DATASET}.csv"
LOCAL_FILE="${REFERENCE_DATA_DIR}/${FILE_NAME}"
STAGE_PATH="reference/${FILE_NAME}"
FILE_SIZE=0

RUN_TOKEN="REFERENCE_${DATASET}_$(date '+%Y%m%d%H%M%S')_$$"
UPLOAD_LOG="${LOG_DIR}/stage_upload_${RUN_TOKEN}.log"
STAGE_LIST_LOG="${LOG_DIR}/stage_list_${RUN_TOKEN}.log"
METADATA_LOG="${LOG_DIR}/stage_metadata_${RUN_TOKEN}.log"

CURRENT_OPERATION="input validation"

# -----------------------------------------------------------------------------
# Step 1 - Validate input
# -----------------------------------------------------------------------------

info "Step 1 - Validate input"
info "Validating reference dataset ${DATASET}."

[[ "$DATASET" =~ ^(customers|products|sellers|geolocation|category_translation)$ ]] ||
    fail_stage "Unsupported reference dataset '${DATASET}'."

[[ -f "$LOCAL_FILE" ]] ||
    fail_stage "Reference CSV not found: ${LOCAL_FILE}"

for command_name in snow grep wc tr; do
    require_command "$command_name" ||
        fail_stage "Required command is unavailable: ${command_name}"
done

FILE_SIZE="$(wc -c < "$LOCAL_FILE" | tr -d '[:space:]')"
success "Source file validated: ${LOCAL_FILE} (${FILE_SIZE} bytes)."
info "Stage destination: ${SNOWFLAKE_STAGE}/${STAGE_PATH}"
info "Run token: ${RUN_TOKEN}"

# -----------------------------------------------------------------------------
# Step 2 - Check and stage source file
# -----------------------------------------------------------------------------

CURRENT_OPERATION="checking Snowflake stage"
info "Step 2 - Check and stage source file"
info "Checking whether ${FILE_NAME} exists at ${SNOWFLAKE_STAGE}/reference/."

if STAGE_LISTING="$(snow_sql --format CSV --silent \
    -q "LIST ${SNOWFLAKE_STAGE}/reference/" 2>"$STAGE_LIST_LOG")"; then
    STAGED="$(printf '%s\n' "$STAGE_LISTING" | grep -F "$FILE_NAME" || true)"
else
    error "Could not list the Snowflake stage. Details: ${STAGE_LIST_LOG}"
    show_log_tail "$STAGE_LIST_LOG"
    fail_stage "Stage listing failed; check the Snowflake connection and stage permissions."
fi

if [[ -n "$STAGED" ]]; then
    info "File already exists in the stage; upload skipped."
else
    CURRENT_OPERATION="uploading source file"
    info "Uploading ${LOCAL_FILE} to ${SNOWFLAKE_STAGE}/reference/."

    if snow stage copy \
        "$LOCAL_FILE" \
        "${SNOWFLAKE_STAGE}/reference/" \
        --connection "$SNOWFLAKE_CONNECTION" >"$UPLOAD_LOG" 2>&1; then
        success "Upload command completed. Details: ${UPLOAD_LOG}"
    else
        error "Upload failed. Details: ${UPLOAD_LOG}"
        show_log_tail "$UPLOAD_LOG"
        fail_stage "Could not upload ${FILE_NAME} to the Snowflake stage."
    fi

    CURRENT_OPERATION="verifying staged file"
    info "Verifying uploaded file in the Snowflake stage."

    if STAGE_LISTING="$(snow_sql --format CSV --silent \
        -q "LIST ${SNOWFLAKE_STAGE}/reference/" 2>"$STAGE_LIST_LOG")"; then
        STAGED="$(printf '%s\n' "$STAGE_LISTING" | grep -F "$FILE_NAME" || true)"
    else
        error "Stage listing failed during upload verification. Details: ${STAGE_LIST_LOG}"
        show_log_tail "$STAGE_LIST_LOG"
        fail_stage "Could not verify the uploaded file."
    fi

    [[ -n "$STAGED" ]] ||
        fail_stage "Upload command succeeded, but '${STAGE_PATH}' was not found in the stage."

    success "File verified in the Snowflake stage."
fi

# -----------------------------------------------------------------------------
# Step 3 - Record staging metadata
# -----------------------------------------------------------------------------

CURRENT_OPERATION="recording stage metadata"
info "Step 3 - Record staging metadata"
info "Recording metadata for ${STAGE_PATH}."

if snow_sql \
    -D FILE_PATH="$STAGE_PATH" \
    -D FILE_NAME="$FILE_NAME" \
    -D BATCH_ID="$BATCH_ID" \
    -D FILE_CATEGORY="REFERENCE" \
    -f "$STAGE_FILE_LOG_SQL" >"$METADATA_LOG" 2>&1; then
    success "Stage metadata recorded. Details: ${METADATA_LOG}"
else
    error "Stage metadata recording failed. Details: ${METADATA_LOG}"
    show_log_tail "$METADATA_LOG"
    fail_stage "Could not record staging metadata for ${STAGE_PATH}."
fi

# -----------------------------------------------------------------------------
# Step 4 - Send staging notification
# -----------------------------------------------------------------------------

CURRENT_OPERATION="preparing staging notification"
info "Step 4 - Send staging notification"

send_mail \
    "[RETAIL DW] STAGING SUCCESS - ${DATASET^^}" \
    "RETAIL DATA PLATFORM - STAGING STATUS REPORT

Status        : STAGED
Batch ID      : ${BATCH_ID}
Dataset       : ${DATASET^^}
Source File   : ${FILE_NAME}
File Category : REFERENCE
Local Path    : ${LOCAL_FILE}
Stage         : ${SNOWFLAKE_STAGE}
Stage Path    : ${STAGE_PATH}
File Size     : ${FILE_SIZE} bytes
Timestamp     : $(date '+%Y-%m-%d %H:%M:%S')
Connection    : ${SNOWFLAKE_CONNECTION}
Database      : ${SNOWFLAKE_DATABASE}
Schema        : ${SNOWFLAKE_SCHEMA}
Run Token     : ${RUN_TOKEN}

Result: The file is verified in the Snowflake stage and its metadata was recorded."

success "Staging notification processed."
success "Reference staging completed: dataset=${DATASET}, stage_path=${STAGE_PATH}."
