#!/usr/bin/env bash
# Cafe — a Reflector issue: the ERC-20 named "Cafe" minted by
# USDCReflector.issue("Cafe", variant). USDCReflector is the Reflector
# clone pegged to chain-local Circle USDC; it issues through its coinage
# (the Lepton prototype), so this is a Lepton clone whose maker is the
# USDCReflector clone and whose symbol/decimals/supply are fixed by
# Reflector for a USDC peg. The same prediction holds on every chain.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300 # Lepton

maker=0x05dD50aD3A40629E62635Ea67Dd17C6a0a3cb388 # USDCReflector
name=Cafe               # issue name
symbol=1xUSDC           # USDCReflector.symbol()
decimals=6              # USDC peg decimals
supply=1000000000000000 # 1e15

mask=0xffff00000000000000000000000000000000ffff
target=0xcafe00000000000000000000000000000000cafe

clone_predict CafeUSDC "$deployer" \
    "address,string,string,uint8,uint256" "$maker" "$name" "$symbol" "$decimals" "$supply" \
    0x0000000000000000000000000000000000000000000000000000000016481b64
