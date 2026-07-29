#!/usr/bin/env bash
# Production entry point; implementation is shared with the validated batch.
set -Eeuo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cmp90hx-batch-bus-test.sh" "$@"
