#!/usr/bin/env bash
# USDCReflector — clone of Reflector that issues 1xUSDC against the
# chain-local Circle USDC. The peg is the USDC AddressLookup so the
# same prediction holds on every chain.
#
# Deps (hardcoded with provenance — update after re-running any
# upstream predict script):
#   deployer ← unispring/io/Reflector/        (same repo, the Reflector prototype)
#   peg      ← uniswap-lookup/io/USDC/        (sibling repo, the Circle-USDC AddressLookup)
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

deployer=0xBdbDe564c4e4dEA7E98BAFa4733fE41158E2e091

peg=0xC5DC3461ed6653dbC5E6A8bCDcF0354fF178E300 # USDC Lookup
symbol=1xUSDC

# Vanity-mining inputs — TODO: re-mine. The variant below is stale.
mask=0xffffff0000000000000000000000000000000000
target=0x05dd500000000000000000000000000000000000

variant=0x0000000000000000000000000000000000000000000000000000000000e1f45e

clone_predict USDCReflector "$deployer" "address,string" "$peg" "$symbol" "$variant"
