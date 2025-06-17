#!/bin/bash

# Set your constructor arguments
USDC="0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"  # USDC mainnet address
MULTISIG="0x3dFc49e5112005179Da613BdE5973229082dAc35"
MERKLE_ROOT="0x0000000000000000000000000000000000000000000000000000000000000000"  # Empty root (can be set later)
START_DATE="1750276800"  # July 18, 2025
END_DATE="1750881600"    # July 25, 2025

# Deploy and capture output
deploy_output=$(forge create src/ZhengLongIDO.sol:ZhengLongIDO \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --chain-id 1 \
  --verify \
  --broadcast \
  --constructor-args "$USDC" "$MULTISIG" "$MERKLE_ROOT" "$START_DATE" "$END_DATE")

# Extract the deployed address
ido_address=$(echo "$deploy_output" | grep "Deployed to:" | awk '{print $3}')

# Display the deployed address
echo "ZhengLongIDO deployed at: $ido_address"