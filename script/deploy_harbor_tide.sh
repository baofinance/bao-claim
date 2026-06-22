#!/usr/bin/env bash
# Legacy wrapper — use script/deploy.sh instead.
exec "$(dirname "$0")/deploy.sh" "$@"
