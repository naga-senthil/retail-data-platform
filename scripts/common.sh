
#!/usr/bin/env bash

# Shared configuration and logging helpers for the Retail Data Platform.
# Run pipeline scripts from the project root so SQL/data paths resolve correctly.

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Snowflake connection and object configuration
# -----------------------------------------------------------------------------

SNOWFLAKE_CONNECTION="${SNOWFLAKE_CONNECTION:-${CONNECTION:-retail-data}}"
SNOWFLAKE_DATABASE="${SNOWFLAKE_DATABASE:-RETAIL_DW}"
SNOWFLAKE_SCHEMA="${SNOWFLAKE_SCHEMA:-BRONZE}"
SNOWFLAKE_STAGE="${SNOWFLAKE_STAGE:-${STAGE:-@RETAIL_DW.BRONZE.RETAIL_STAGE}}"
SNOWFLAKE_FILE_FORMAT="${SNOWFLAKE_FILE_FORMAT:-${FORMAT:-RETAIL_DW.BRONZE.CSV_FORMAT}}"

# -----------------------------------------------------------------------------
# Local directory configuration
# -----------------------------------------------------------------------------

DAILY_BATCH_DIR="${DAILY_BATCH_DIR:-${BATCH_DIR:-data/batches/daily}}"
REFERENCE_DATA_DIR="${REFERENCE_DATA_DIR:-data/batches/reference}"
REJECTED_DATA_DIR="${REJECTED_DATA_DIR:-${REJECTED_DIR:-data/batches/rejected}}"
LOG_DIR="${LOG_DIR:-logs}"

# -----------------------------------------------------------------------------
# Snowflake SQL template paths
# -----------------------------------------------------------------------------

STAGE_FILE_LOG_SQL="${STAGE_FILE_LOG_SQL:-snowflake/bronze/merge_stage_file_log.sql}"
CHECK_LOAD_STATUS_SQL="${CHECK_LOAD_STATUS_SQL:-snowflake/bronze/select_load_status.sql}"
AUDIT_START_SQL="${AUDIT_START_SQL:-snowflake/bronze/insert_load_audit_start.sql}"
AUDIT_UPDATE_SQL="${AUDIT_UPDATE_SQL:-snowflake/bronze/update_load_audit.sql}"
TRUNCATE_BRONZE_SQL="${TRUNCATE_BRONZE_SQL:-snowflake/bronze/truncate_bronze_table.sql}"
COPY_INTO_BRONZE_SQL="${COPY_INTO_BRONZE_SQL:-snowflake/bronze/copy_into_bronze.sql}"
VALIDATE_COPY_ERRORS_SQL="${VALIDATE_COPY_ERRORS_SQL:-snowflake/bronze/validate_copy_errors.sql}"

# -----------------------------------------------------------------------------
# Backwards-compatible configuration names
# -----------------------------------------------------------------------------

CONNECTION="$SNOWFLAKE_CONNECTION"
BATCH_DIR="$DAILY_BATCH_DIR"
STAGE="$SNOWFLAKE_STAGE"
FORMAT="$SNOWFLAKE_FILE_FORMAT"
REJECTED_DIR="$REJECTED_DATA_DIR"

# -----------------------------------------------------------------------------
# Initialize directories and execution state
# -----------------------------------------------------------------------------

mkdir -p "$LOG_DIR" "$REJECTED_DATA_DIR"

CURRENT_OPERATION="initialization"
LOAD_AUDIT_STARTED=0
STEP=0

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

log() {
    printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

info() {
    log "INFO    | $*"
}

success() {
    log "SUCCESS | $*"
}

warn() {
    log "WARNING | $*" >&2
}

error() {
    log "ERROR   | $*" >&2
}

# Compatibility alias for scripts that still use logit.
logit() {
    info "$*"
}

# -----------------------------------------------------------------------------
# Step logging helpers
# -----------------------------------------------------------------------------

start_step() {
    STEP=$((STEP + 1))
    CURRENT_OPERATION="$1"
    log "Step ${STEP} - ${CURRENT_OPERATION}"
}

complete_step() {
    success "${CURRENT_OPERATION} completed."
}

# -----------------------------------------------------------------------------
# Snowflake CLI helpers
# -----------------------------------------------------------------------------

snow_sql() {
    snow sql --connection "$SNOWFLAKE_CONNECTION" "$@"
}

sql_scalar() {
    snow_sql --format CSV --silent "$@" |
        tail -n 1 |
        tr -d '\r"'
}

require_command() {
    local command_name="$1"

    if ! command -v "$command_name" >/dev/null 2>&1; then
        error "Required command not found: ${command_name}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Log-file troubleshooting helper
# -----------------------------------------------------------------------------

show_log_tail() {
    local file_path="$1"
    local max_lines="${2:-8}"

    [[ -f "$file_path" ]] || return 0

    while IFS= read -r line; do
        [[ -n "$line" ]] && error "DETAIL | ${line}"
    done < <(tail -n "$max_lines" "$file_path")
}

# -----------------------------------------------------------------------------
# Load audit helpers
# -----------------------------------------------------------------------------

audit_start() {
    local batch_id="$1"
    local file_path="$2"
    local target_table="$3"
    local run_token="$4"
    local output_log="${LOG_DIR}/audit_start_${run_token}.log"

    if snow_sql \
        -D BATCH_ID="$batch_id" \
        -D FILE_PATH="$file_path" \
        -D TARGET_TABLE="$target_table" \
        -D RUN_TOKEN="$run_token" \
        -f "$AUDIT_START_SQL" >"$output_log" 2>&1; then

        log "Load audit started: batch=${batch_id} file=${file_path} table=${target_table}"
        return 0
    fi

    error "Could not create load audit record. Details: ${output_log}"
    show_log_tail "$output_log"
    return 1
}

audit_update() {
    local run_token="$1"
    local load_status="$2"
    local rows_parsed="$3"
    local rows_loaded="$4"
    local rows_skipped="$5"
    local error_count="$6"
    local error_message="$7"

    local log_suffix
    log_suffix="$(date '+%H%M%S')_$$"

    local output_log="${LOG_DIR}/audit_update_${run_token}_${log_suffix}.log"

    if snow_sql \
        -D RUN_TOKEN="$run_token" \
        -D LOAD_STATUS="$load_status" \
        -D ROWS_PARSED="$rows_parsed" \
        -D ROWS_LOADED="$rows_loaded" \
        -D ROWS_SKIPPED="$rows_skipped" \
        -D ERROR_COUNT="$error_count" \
        -D ERROR_MESSAGE="$error_message" \
        -f "$AUDIT_UPDATE_SQL" >"$output_log" 2>&1; then

        log "Load audit updated: status=${load_status} run_token=${run_token}"
        return 0
    fi

    error "Could not update load audit to ${load_status}. Details: ${output_log}"
    show_log_tail "$output_log"
    return 1
}

# -----------------------------------------------------------------------------
# Notification helper
# -----------------------------------------------------------------------------

# This is a logging stub unless an email transport is configured separately.
send_mail() {
    local subject="${1:-Notification}"
    local body="${2:-}"

    : "$body"

    info "Notification prepared: ${subject} (email delivery is not configured in common.sh)."
}

# -----------------------------------------------------------------------------
# Failure handlers
# -----------------------------------------------------------------------------

fail_load() {
    local error_message="${1:-Unexpected load failure}"
    local operation="${CURRENT_OPERATION:-unknown operation}"

    error "LOAD FAILED | batch=${BATCH_ID:-unknown} dataset=${DATASET:-unknown} operation=${operation} | ${error_message}"

    if [[ "${LOAD_AUDIT_STARTED:-0}" == "1" && -n "${RUN_TOKEN:-}" ]]; then
        audit_update \
            "$RUN_TOKEN" \
            "FAILED" \
            "${ROWS_PARSED:-0}" \
            "${ROWS_LOADED:-0}" \
            "${ROWS_SKIPPED:-0}" \
            "${ERROR_COUNT:-1}" \
            "${operation}: ${error_message}" || true

        LOAD_AUDIT_STARTED=0
    fi

    send_mail \
        "[RETAIL DW] LOAD FAILED - ${DATASET:-unknown}" \
        "Batch: ${BATCH_ID:-unknown}
Dataset: ${DATASET:-unknown}
Operation: ${operation}
Error: ${error_message}
Run token: ${RUN_TOKEN:-unknown}"

    exit 1
}

# Compatibility alias for older scripts that use fail_step.
fail_step() {
    local error_message="${1:-Unexpected pipeline failure}"
    fail_load "$error_message"
}

fail_stage() {
    local error_message="${1:-Unexpected staging failure}"
    local operation="${CURRENT_OPERATION:-unknown operation}"

    error "STAGING FAILED | batch=${BATCH_ID:-unknown} dataset=${DATASET:-unknown} operation=${operation} | ${error_message}"

    send_mail \
        "[RETAIL DW] STAGING FAILED - ${DATASET:-unknown}" \
        "Batch: ${BATCH_ID:-unknown}
Dataset: ${DATASET:-unknown}
File: ${FILE_NAME:-unknown}
Operation: ${operation}
Error: ${error_message}
Run token: ${RUN_TOKEN:-unknown}"

    exit 1
}
