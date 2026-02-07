#!/bin/bash
# start.sh — alias for run.sh (kept for backward compatibility)
exec "$(dirname "$0")/run.sh" "$@"
