#!/usr/bin/env bash
# Dadda — a Reflector issue: the ERC-20 named "Dadda" minted by
# USDCReflector.issue("Dadda", variant). USDCReflector is the Reflector
# clone pegged to chain-local Circle USDC; it issues through its coinage
# (the Lepton prototype), so this is a Lepton clone whose maker is the
# USDCReflector clone and whose symbol/decimals/supply are fixed by
# Reflector for a USDC peg. The same prediction holds on every chain.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

# Lepton prototype — Reflector.coinage, the ICoinage that issue() calls.
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300

# msg.sender of coinage.make inside Reflector.issue is the USDCReflector
# clone; Lepton records it as `maker` in the salt.
maker=0x05dD50aD3A40629E62635Ea67Dd17C6a0a3cb388
name=Dadda                  # issue name
symbol=1xUSDC               # USDCReflector.symbol()
decimals=6                  # USDC peg decimals
# Reflector._issueMetadata for a 6-decimal peg: maxSupply (1e27) scaled
# down by 10**(18-6) → 1e15.
supply=1000000000000000

# Vanity-mining inputs — TODO: re-mine. The variant below is stale;
# changing name/supply changes argshash, so it must be re-mined anyway.
mask=0xfffff000000000000000000000000000000fffff
target=0xdadda000000000000000000000000000000dadda

clone_predict Dadda "$deployer" \
    "address,string,string,uint8,uint256" "$maker" "$name" "$symbol" "$decimals" "$supply" \
    0x0000000000000000000000000000000000000000000000000000001f961515f9
