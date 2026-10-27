
#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

LATEST_COMPLETE_BATCH="$(
    sql_scalar -f snowflake/bronze/select_latest_complete_batch.sql
)"

LATEST_COMPLETE_BATCH="${LATEST_COMPLETE_BATCH:-00000000}"

[[ "$LATEST_COMPLETE_BATCH" =~ ^[0-9]{8}$ ]] || {
    log "ERROR: Invalid latest batch value: ${LATEST_COMPLETE_BATCH}" >&2
    exit 2
}

while IFS= read -r BATCH_DIR_PATH; do
    [[ -d "$BATCH_DIR_PATH" ]] || continue

    NEXT_BATCH="${BATCH_DIR_PATH##*/batch_}"

    [[ "$NEXT_BATCH" =~ ^[0-9]{8}$ ]] || continue

    if [[ "$NEXT_BATCH" > "$LATEST_COMPLETE_BATCH" ]]; then
        log "Next batch selected: ${NEXT_BATCH}" >&2
        printf '%s\n' "$NEXT_BATCH"
        exit 0
    fi
done < <(printf '%s\n' "${DAILY_BATCH_DIR}"/batch_* | sort)

log "No pending batch found after ${LATEST_COMPLETE_BATCH}" >&2
exit 1
