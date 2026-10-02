#!/bin/sh
# Compatibility alias. quiet.sh owns the entire pass.
set -eu
if [ "${BENCH_MODE:-full}" = smoke ]; then
    exec "$(dirname -- "$0")/quiet.sh" --smoke "$@"
fi
exec "$(dirname -- "$0")/quiet.sh" "$@"
