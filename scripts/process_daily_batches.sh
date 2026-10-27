
#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DAILY_DATASETS=(
    orders
    order_items
    order_payments
    order_reviews
)

require_command snow

log "========== Daily Bronze pipeline started =========="

if ! NEXT_BATCH="$("${SCRIPT_DIR}/get_next_batch.sh")"; then
    log "No pending batch found. Nothing to do."
    exit 0
fi

BATCH_ID="$NEXT_BATCH"

log "Processing batch: ${BATCH_ID}"

for DATASET in "${DAILY_DATASETS[@]}"; do
    log "============================================================"
    log "Starting dataset processing: ${DATASET}"
    log "Batch ID: ${BATCH_ID}"
    log "============================================================"

    log "[${DATASET}] Step 1/2 - Starting file staging"

    "${SCRIPT_DIR}/stage_file.sh" \
        "$BATCH_ID" \
        "$DATASET"

    log "[${DATASET}] Step 1/2 - File staging completed"
    log "------------------------------------------------------------"
    log "[${DATASET}] Step 2/2 - Starting Bronze load"

    "${SCRIPT_DIR}/load_file.sh" \
        "$BATCH_ID" \
        "$DATASET"

    log "[${DATASET}] Step 2/2 - Bronze load completed"

    log "Completed dataset processing: ${DATASET}"
done

log "========== Batch ${BATCH_ID} completed =========="
