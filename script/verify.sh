#!/usr/bin/env bash
set -euo pipefail

# Verify HarborTideDistributor_v1 on Etherscan (V2), reading the deployed address and constructor
# args from deployments/aux-<chainId>.json (written by script/deploy.sh).
# Failures don't abort the run; a summary is printed and a non-zero exit returned if anything failed.

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"
# shellcheck source=script/_load-env.sh
source "$ROOT_DIR/script/_load-env.sh"

FORGE=${FORGE:-forge}
CAST=${CAST:-cast}

SOLC="0.8.30"
DISTRIBUTOR_PATH="src/tide/HarborTideDistributor_v1.sol:HarborTideDistributor_v1"

VERIFY_RETRIES="${VERIFY_RETRIES:-12}"
VERIFY_DELAY="${VERIFY_DELAY:-20}"

usage() {
  cat <<'EOF'
Usage:
  script/verify.sh --network <name> [--aux <path>]

Options:
  --network <name>   Required. rpc_endpoints key in foundry.toml (mainnet|local).
  --aux <path>       Explicit aux JSON path (overrides the default).
  -h, --help         Show help.
EOF
}

NETWORK=""
AUX_OVERRIDE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --network) NETWORK=${2:-}; shift 2 ;;
    --aux) AUX_OVERRIDE=${2:-}; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) echo "❌ Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "$NETWORK" ]] || { echo "❌ Missing --network" >&2; usage >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq is required" >&2; exit 1; }
[[ -n "${ETHERSCAN_API_KEY:-}" ]] || { echo "❌ ETHERSCAN_API_KEY is not set" >&2; exit 1; }

RPC_URL=$(resolve_rpc_url "$NETWORK")
CHAIN_ID=$("$CAST" chain-id --rpc-url "$RPC_URL")

AUX=${AUX_OVERRIDE:-"deployments/aux-${CHAIN_ID}.json"}
[[ -f "$AUX" ]] || { echo "❌ Aux file not found: $AUX" >&2; exit 1; }

DISTRIBUTOR=$(jq -r '.distributor // empty' "$AUX")
TIDE=$(jq -r '.tide // empty' "$AUX")
BAO=$(jq -r '.bao // empty' "$AUX")
VEBAO=$(jq -r '.veBao // empty' "$AUX")
START_DATE=$(jq -r '.startDate // empty' "$AUX")
END_DATE=$(jq -r '.endDate // empty' "$AUX")
SNAPSHOT_BLOCK=$(jq -r '.snapshotBlock // empty' "$AUX")
MULTISIG=$(jq -r '.multisig // empty' "$AUX")
VE_ROOT=$(jq -r '.veBaoMerkleRoot // empty' "$AUX")
STD_ROOT=$(jq -r '.standardMerkleRoot // empty' "$AUX")

echo "=== Verify HarborTideDistributor_v1 ==="
echo "  network:     $NETWORK (chainId $CHAIN_ID)"
echo "  aux:         $AUX"
echo "  distributor: $DISTRIBUTOR"
echo ""

ok=0; fail=0; skip=0

verify_one() {
  local address=$1 contract_path=$2 ctor_args=$3 compiler=$4 label=$5

  if [[ -z "$address" || "$address" == "0x0000000000000000000000000000000000000000" ]]; then
    echo "⏭  Skip $label: no address"; skip=$((skip + 1)); return
  fi
  local code
  code=$("$CAST" code "$address" --rpc-url "$RPC_URL" 2>/dev/null | head -n 1 || echo "0x")
  if [[ "$code" == "0x" ]]; then
    echo "⏭  Skip $label ($address): no code on-chain"; skip=$((skip + 1)); return
  fi

  local -a cmd
  cmd=("$FORGE" verify-contract "$address" "$contract_path"
    --verifier etherscan --etherscan-api-key "$ETHERSCAN_API_KEY"
    --compiler-version "$compiler" --chain "$NETWORK"
    --watch --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY")
  [[ -n "$ctor_args" ]] && cmd+=(--constructor-args "$ctor_args")

  local out
  out=$("${cmd[@]}" 2>&1 || true)
  if echo "$out" | grep -qiE "successfully verified|already verified"; then
    echo "✅ $label ($address)"; ok=$((ok + 1))
  else
    echo "❌ $label ($address)"; echo "$out" | grep -iE "error|fail" | head -5 | sed 's/^/   /'
    fail=$((fail + 1))
  fi
}

CTOR=$("$CAST" abi-encode \
  "constructor(address,address,address,uint256,uint256,uint256,address,bytes32,bytes32)" \
  "$TIDE" "$BAO" "$VEBAO" "$START_DATE" "$END_DATE" "$SNAPSHOT_BLOCK" "$MULTISIG" "$VE_ROOT" "$STD_ROOT")

verify_one "$DISTRIBUTOR" "$DISTRIBUTOR_PATH" "$CTOR" "$SOLC" "HarborTideDistributor_v1"

echo ""
echo "Done: ok=$ok fail=$fail skip=$skip"
[[ $fail -eq 0 ]]
