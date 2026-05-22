#!/usr/bin/env bash
# GoodFood — a Reflector issue: the ERC-20 named "Good Food" minted by
# USDCReflector.issue("Good Food", variant). USDCReflector is the Reflector
# clone pegged to chain-local Circle USDC; it issues through its coinage
# (the Lepton prototype), so this is a Lepton clone whose maker is the
# USDCReflector clone and whose symbol/decimals/supply are fixed by
# Reflector for a USDC peg. The same prediction holds on every chain.
clone=GoodFood
# Lepton prototype — Reflector.coinage, the ICoinage that issue() calls.
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300

# msg.sender of coinage.make inside Reflector.issue is the USDCReflector
# clone; Lepton records it as `maker` in the salt.
maker=0x05dD50aD3A40629E62635Ea67Dd17C6a0a3cb388
name="Good Food"             # issue name
symbol=1xUSDC               # USDCReflector.symbol()
decimals=6                  # USDC peg decimals
# Reflector._issueMetadata for a 6-decimal peg: maxSupply (1e27) scaled
# down by 10**(18-6) → 1e15.
supply=1000000000000000

# Vanity-mining inputs — TODO: re-mine. The variant below is stale;
# changing name/supply changes argshash, so it must be re-mined anyway.
mask=0xffff00000000000000000000000000000000ffff
target=0x600d00000000000000000000000000000000f00d

variant=0x00000000000000000000000000000000000000000000000000000000b4551d0b

source "$(git rev-parse --show-toplevel)/io/predictReflection.sh"
