#!/usr/bin/env bash
set -euo pipefail

# Deploy HarborTideDistributor_v1 (one-shot, non-upgradeable TGE distributor).
# Wraps script/DeployTideDistributor.s.sol. Mainnet-only in practice (veBAO snapshot is Ethereum).
#
# Constructor args are read from deployments/deploy-config.json (see deploy-config.example.json).
# Override path with --config or DEPLOY_CONFIG_FILE.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=script/_load-env.sh
source "$ROOT_DIR/script/_load-env.sh"

FORGE=${FORGE:-forge}
CAST=${CAST:-cast}

TIMEOUT="${DEPLOY_TIMEOUT:-900}"
VERIFY_RETRIES="${VERIFY_RETRIES:-12}"
VERIFY_DELAY="${VERIFY_DELAY:-20}"
DEFAULT_CONFIG="deployments/deploy-config.json"

usage() {
  cat <<'EOF'
Usage:
  script/deploy.sh --network <name> [--config <path>] [--account <keystore>] [--sender <addr>] [--no-verify] [--resume]

Options:
  --network <v>      Required. rpc_endpoints key (mainnet|local) or a raw RPC URL.
  --config <path>    Deploy config JSON (default: deployments/deploy-config.json).
  --account <name>   Foundry keystore account (default: $DEPLOYER_ACCOUNT or "deployer"). Or set PRIVATE_KEY.
  --sender <addr>    Deployer EOA (default: derived from the keystore account).
  --no-verify        Skip Etherscan verification (default: on when ETHERSCAN_API_KEY is set).
  --resume           Pass --resume to forge (continue an interrupted broadcast).
  -h, --help         Show help.
EOF
}

NETWORK=""
CONFIG_PATH="${DEPLOY_CONFIG_FILE:-$DEFAULT_CONFIG}"
ACCOUNT="${DEPLOYER_ACCOUNT:-deployer}"
SENDER=""
VERIFY=true
RESUME=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK=${2:-}; shift 2 ;;
    --config) CONFIG_PATH=${2:-}; shift 2 ;;
    --account) ACCOUNT=${2:-}; shift 2 ;;
    --sender) SENDER=${2:-}; shift 2 ;;
    --no-verify) VERIFY=false; shift ;;
    --resume) RESUME=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -f foundry.toml ]] || { echo "❌ Run from the repo root" >&2; exit 1; }
[[ -n "$NETWORK" ]] || { echo "❌ Missing --network" >&2; usage >&2; exit 1; }
[[ -f "$CONFIG_PATH" ]] || {
  echo "❌ Deploy config not found: $CONFIG_PATH" >&2
  echo "   Copy deployments/deploy-config.example.json to deployments/deploy-config.json and fill in values." >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || { echo "❌ jq is required" >&2; exit 1; }

# Validate required config fields before broadcasting.
missing=()
for key in tide bao startDate endDate veBaoMerkleRoot; do
  val=$(jq -r --arg k "$key" '.[$k] // empty' "$CONFIG_PATH")
  if [[ -z "$val" || "$val" == "null" || "$val" == "0x0000000000000000000000000000000000000000" || "$val" == "0" ]]; then
  missing+=("$key")
  fi
done
std_root=$(jq -r '.standardMerkleRoot // empty' "$CONFIG_PATH")
if [[ -z "$std_root" || "$std_root" == "null" ]]; then
  missing+=("standardMerkleRoot")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "❌ Missing or placeholder values in $CONFIG_PATH: ${missing[*]}" >&2
  exit 1
fi

export DEPLOY_CONFIG_FILE="$CONFIG_PATH"

SIGNER=()
if [[ -n "${PRIVATE_KEY:-}" ]]; then
  SIGNER=(--private-key "$PRIVATE_KEY")
  [[ -n "$SENDER" ]] || SENDER=$("$CAST" wallet address --private-key "$PRIVATE_KEY")
else
  if [[ -z "${DEPLOYER_ACCOUNT_PASSWORD:-}" ]]; then
    read -r -s -p "Keystore password for \"$ACCOUNT\" (hidden): " DEPLOYER_ACCOUNT_PASSWORD
    echo ""
    export DEPLOYER_ACCOUNT_PASSWORD
  fi
  SIGNER=(--account "$ACCOUNT" --password "$DEPLOYER_ACCOUNT_PASSWORD")
  [[ -n "$SENDER" ]] || SENDER=$("$CAST" wallet address "${SIGNER[@]}")
fi

if [[ "$VERIFY" == true ]] && [[ -z "${ETHERSCAN_API_KEY:-}" ]]; then
  echo "⚠️  ETHERSCAN_API_KEY not set; continuing without --verify (run script/verify.sh later)."
  VERIFY=false
fi

RPC_URL=$(resolve_rpc_url "$NETWORK")
CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_URL")

TIDE=$(jq -r '.tide' "$CONFIG_PATH")
BAO=$(jq -r '.bao' "$CONFIG_PATH")
START_DATE=$(jq -r '.startDate' "$CONFIG_PATH")
END_DATE=$(jq -r '.endDate' "$CONFIG_PATH")

echo ""
echo "=== HarborTideDistributor_v1 deploy — $NETWORK (chainId $CHAIN_ID) ==="
echo "  sender: $SENDER   verify: $VERIFY"
echo "  config: $CONFIG_PATH"
echo "  tide:   $TIDE"
echo "  bao:    $BAO"
echo "  window: $START_DATE -> $END_DATE"

cmd=("$FORGE" script script/DeployTideDistributor.s.sol:DeployTideDistributor
  --rpc-url "$RPC_URL" --broadcast --slow --timeout "$TIMEOUT" --sender "$SENDER" "${SIGNER[@]}")
[[ "$VERIFY" == true ]] && cmd+=(--verify --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY")
[[ "$RESUME" == true ]] && cmd+=(--resume)
"${cmd[@]}"

echo ""
echo "Deploy complete. Aux record: deployments/aux-${CHAIN_ID}.json"
echo "Next: fund the distributor with up to 280,000,000 TIDE."
echo "Verify later with: script/verify.sh --network $NETWORK"
