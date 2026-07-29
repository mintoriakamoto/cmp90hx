#!/usr/bin/env bash
# Production entry point; implementation is shared with the validated wrapper.
set -Eeuo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cmp90hx-defer-hive-services.sh" "$@"
