#!/bin/bash

# Deploy HarborTideDistributor_v1 (one-shot, non-upgradeable TGE distributor).
#
# Constructor args (order matters):
#   tide_              TIDE claim token address (deployed + funded separately)
#   bao_               BAO swap input token address
#   veBao_             veBAO voting escrow address
#   startDate_         Unix timestamp the claim window opens (MUST be after block 25,000,000)
#   endDate_           Unix timestamp the claim window closes
#   snapshotBlock_     veBAO eligibility snapshot block (25,000,000 on mainnet)
#   multisig_          Owner, BAO recipient, and post-window sweep destination
#   veBaoMerkleRoot_   Path-2 veBAO merkle root (leaves: (address, tideAmount) in TIDE)
#   standardMerkleRoot_ Path-3 standard merkle root (leaves: (address, tideAmount) in TIDE)
#
# After deploy: fund the contract with up to 280,000,000 TIDE
#   (<=250m shared across paths 1+2, <=30m for path 3).
#
# REQUIRED before broadcast — do not deploy with placeholder zeros:
#   TIDE, BAO, START_DATE, END_DATE, VE_MERKLE_ROOT, STANDARD_MERKLE_ROOT

# Set your constructor arguments
# TODO: set mainnet TIDE token address before deploy
TIDE="0x0000000000000000000000000000000000000000"
# TODO: set mainnet BAO token address before deploy
BAO="0x0000000000000000000000000000000000000000"
# Verify this is the live mainnet veBAO voting escrow before broadcasting
VEBAO="0x8bf70dfe40f07a5ab715f7e888478d9d3680a2b6"
# TODO: set claim window open timestamp (must be after block 25,000,000)
START_DATE="0"
# TODO: set claim window close timestamp
END_DATE="0"
SNAPSHOT_BLOCK="25000000"
MULTISIG="0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2"
VE_MERKLE_ROOT="0x0000000000000000000000000000000000000000000000000000000000000000"
STANDARD_MERKLE_ROOT="0x0000000000000000000000000000000000000000000000000000000000000000"

# Deploy and capture output
deploy_output=$(forge create src/tide/HarborTideDistributor_v1.sol:HarborTideDistributor_v1 \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --chain-id 1 \
  --verify \
  --broadcast \
  --constructor-args \
    "$TIDE" \
    "$BAO" \
    "$VEBAO" \
    "$START_DATE" \
    "$END_DATE" \
    "$SNAPSHOT_BLOCK" \
    "$MULTISIG" \
    "$VE_MERKLE_ROOT" \
    "$STANDARD_MERKLE_ROOT")

# Extract the deployed address
distributor_address=$(echo "$deploy_output" | grep "Deployed to:" | awk '{print $3}')

# Display the deployed address
echo "HarborTideDistributor_v1 deployed at: $distributor_address"
echo "Next: fund it with up to 280,000,000 TIDE (<=250m for paths 1+2 shared, <=30m for path 3)."
