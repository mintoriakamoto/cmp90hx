#!/usr/bin/env bash
# Production entry point; implementation is shared with the validated runner.
set -Eeuo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cmp90hx-v67-one-test.sh" "$@"
