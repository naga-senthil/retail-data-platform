
#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

REFERENCE_DATASETS=(
    customers
    products
    sellers
    geolocation
    category_translation
)

require_command snow

log "========== Reference Bronze pipeline started =========="
log "Batch ID: REFERENCE"

for DATASET in "${REFERENCE_DATASETS[@]}"; do
    log "============================================================"
    log "Starting dataset processing: ${DATASET}"
    log "Batch ID: REFERENCE"
    log "============================================================"

    log "[${DATASET}] Step 1/2 - Starting file staging"

    "${SCRIPT_DIR}/stage_reference.sh" \
        "$DATASET"

    log "[${DATASET}] Step 1/2 - File staging completed"
    log "------------------------------------------------------------"
    log "[${DATASET}] Step 2/2 - Starting Bronze load"

    "${SCRIPT_DIR}/load_reference.sh" \
        "$DATASET"

    log "[${DATASET}] Step 2/2 - Bronze load completed"

    log "Completed dataset processing: ${DATASET}"
done

log "========== Reference Bronze pipeline completed =========="
