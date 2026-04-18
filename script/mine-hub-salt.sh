#!/usr/bin/env bash
# Mine a tokenSalt that gives the hub token a vanity address.
# Usage: source .env && chain=bitsy ./script/mine-hub-salt.sh --mask 0x... --match 0x...
#
# Required env (from .env):
#   ICoinage, NeutrinoChannel, NeutrinoSourceProto, HubName, HubSymbol, HubTickLower, HubTickUpper, HubSupply
#
# Required env (from .env):
#   HubSaltMask, HubSaltMatch
#
# All remaining flags are forwarded to saltminer (e.g. --min, --max, --shard).

set -euo pipefail

: "${ICoinage:?}"
: "${NeutrinoChannel:?}"
: "${NeutrinoSourceProto:?}"
: "${HubTickLower:?}"
: "${HubTickUpper:?}"
: "${HubName:?}"
: "${HubSymbol:?}"
: "${HubSupply:?}"
: "${HubSaltMask:?}"
: "${HubSaltMatch:?}"
: "${chain:?set chain to a foundry.toml rpc_endpoints key}"

name="$HubName"
symbol="$HubSymbol"

# --- deployer ---
deployer=$ICoinage

# --- initcode-hash (EIP-1167 proxy keyed to Lepton) ---
initcode_hash=$(cast keccak \
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73${ICoinage#0x}5af43d82803e903d91602b57fd5bf3")

# --- channel (NeutrinoChannel clone for this tick range) ---
channel=$(cast call "$NeutrinoChannel" \
  "made(address,int24,int24)(bool,address,bytes32)" \
  "$NeutrinoSourceProto" "$HubTickLower" "$HubTickUpper" \
  --rpc-url "$chain" | sed -n '2p')

# --- args-hash ---
args_hash=$(cast keccak "$(cast abi-encode \
  "f(address,string,string,uint256)" \
  "$channel" "$name" "$symbol" "$HubSupply")")

echo "deployer      = $deployer"
echo "initcode_hash = $initcode_hash"
echo "channel       = $channel"
echo "args_hash     = $args_hash"
echo

exec saltminer \
  --deployer      "$deployer" \
  --initcode-hash "$initcode_hash" \
  --args-hash     "$args_hash" \
  --mask          "$HubSaltMask" \
  --match         "$HubSaltMatch" \
  "$@"
