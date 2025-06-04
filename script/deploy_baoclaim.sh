#!/bin/bash

# Set your constructor arguments
ROOT="0x8eabd2b36ce185476a0bda6c61aa1584dcad3b6f0ed59b5edc5d23e451f6e290"
START_DATE="1749232800"
END_DATE="1749837600"
GOV="0x3dFc49e5112005179Da613BdE5973229082dAc35"
TOKEN="0xCe391315b414D4c7555956120461D21808A69F3A"
AMOUNT="10581000000000000000000" # 10,581 * 1e18

# Deploy and capture output
deploy_output=$(forge create src/BaoClaim.sol:BaoClaim \
  --rpc-url "$RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --etherscan-api-key "$ETHERSCAN_API_KEY" \
  --chain-id 1 \
  --verify \
  --broadcast \
  --constructor-args "$ROOT" "$START_DATE" "$END_DATE" "$GOV" "$TOKEN" "$AMOUNT")

# Extract the deployed address
baoclaim_address=$(echo "$deploy_output" | grep "Deployed to:" | awk '{print $3}')

# Display the deployed address
echo "BaoClaim deployed at: $baoclaim_address"
