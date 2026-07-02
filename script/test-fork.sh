#!/usr/bin/env bash
set -euo pipefail

# Run HarborTideDistributor_v1 mainnet fork tests.
# Loads MAINNET_RPC_URL from .env (same as script/deploy.sh).

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=script/_load-env.sh
source "$ROOT_DIR/script/_load-env.sh"

FORGE=${FORGE:-forge}
RPC_URL=$(resolve_rpc_url mainnet)

exec "$FORGE" test \
  --match-path "test/tide/HarborTideDistributor_v1.fork.t.sol" \
  --fork-url "$RPC_URL" \
  "$@"
