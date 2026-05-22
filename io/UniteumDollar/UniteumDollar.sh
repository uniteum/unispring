#!/usr/bin/env bash
# UniteumDollar — a Reflector issue: the ERC-20 named "Uniteum Dollar" minted by
# Reflector.issue("Uniteum Dollar", variant). With peg unset (zero address)
# the Reflector prototype itself issues 1xETH; it issues through its
# coinage (the Lepton prototype), so this is a Lepton clone whose
# maker is the Reflector prototype and whose symbol/decimals/supply
# are fixed by Reflector for the ETH peg. The same prediction holds
# on every chain.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

# Lepton prototype — Reflector.coinage, the ICoinage that issue() calls.
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300

maker=0x05dD50aD3A40629E62635Ea67Dd17C6a0a3cb388 # USDCReflector
name="Uniteum Dollar"       # issue name
symbol=1xUSDC               # Reflector.symbol() with unset peg
decimals=18                 # ETH peg decimals
supply=1000000000000000     # 1e15

# Vanity-mining inputs — TODO: re-mine. The variant below is stale;
# changing name/supply changes argshash, so it must be re-mined anyway.
mask=0xfffff0000000000000000000000000000000ffff
target=0x1111100000000000000000000000000000001C5D

clone_predict UniteumDollar "$deployer" \
    "address,string,string,uint8,uint256" "$maker" "$name" "$symbol" "$decimals" "$supply" \
    0x000000000000000000000000000000000000000000000000000000021e195e32
