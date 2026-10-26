
#!/usr/bin/env bash
set -Eeuo pipefail

# Local data preparation only — no Snowflake operations.
exec python scripts/prepare_batches.py "$@"
