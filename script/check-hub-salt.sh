#!/usr/bin/env bash
# Validate a mined hub salt against deployed contracts (read-only, no deployments).
# Usage: source .env && chain=bitsy ./script/check-hub-salt.sh
#
# Required env (from .env):
#   ICoinage, NeutrinoMaker, Neutrino, HubTickLower, HubTickUpper, HubSupply
#   HubSaltMask, HubSaltMatch, HubSalt

set -euo pipefail

: "${ICoinage:?}"
: "${NeutrinoMaker:?}"
: "${Neutrino:?}"
: "${HubTickLower:?}"
: "${HubTickUpper:?}"
: "${HubSupply:?}"
: "${HubSaltMask:?}"
: "${HubSaltMatch:?}"
: "${HubSalt:?}"
: "${chain:?set chain to a foundry.toml rpc_endpoints key}"

name="Hub"
symbol="HUB"

# Ask the NeutrinoMaker prototype for the maker clone address.
maker=$(cast call "$NeutrinoMaker" \
  "made(address,int24,int24)(bool,address,bytes32)" \
  "$Neutrino" "$HubTickLower" "$HubTickUpper" \
  --rpc-url "$chain" | sed -n '2p')

# Ask Lepton for the hub address this salt would produce.
result=$(cast call "$ICoinage" \
  "made(address,string,string,uint256,bytes32)(bool,address,bytes32)" \
  "$maker" "$name" "$symbol" "$HubSupply" "$HubSalt" \
  --rpc-url "$chain")

deployed=$(echo "$result" | sed -n '1p')
hub=$(echo "$result" | sed -n '2p')

echo "maker    = $maker"
echo "hub      = $hub"
echo "deployed = $deployed"

# Verify the vanity pattern: (hub & mask) == match using python for 160-bit math.
python3 -c "
hub    = int('$hub', 16)
mask   = int('$HubSaltMask', 16)
match  = int('$HubSaltMatch', 16)
masked = hub & mask
if masked == match:
    print('PASS: hub matches vanity pattern')
else:
    print(f'FAIL: (hub & mask) = {masked:#042x}, expected {match:#042x}')
    exit(1)
"

if [ "$deployed" = "true" ]; then
  echo "NOTE: hub already deployed at $hub"
fi
