#!/usr/bin/env bash
# BitsyEth — a Reflector issue: the ERC-20 named "Bitsy ETH" minted by
# Reflector.issue("Bitsy ETH", variant). With peg unset (zero address)
# the Reflector prototype itself issues 1xETH; it issues through its
# coinage (the Lepton prototype), so this is a Lepton clone whose
# maker is the Reflector prototype and whose symbol/decimals/supply
# are fixed by Reflector for the ETH peg. The same prediction holds
# on every chain.
clone=BitsyEth
# Lepton prototype — Reflector.coinage, the ICoinage that issue() calls.
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300

# msg.sender of coinage.make inside Reflector.issue is the Reflector
# prototype itself (peg is unset, so no Reflector clone is involved);
# Lepton records it as `maker` in the salt.
maker=0xBDbd6217ADFe1f3AE9fd4eC4D82d62A3a9baE090
name="Bitsy ETH"            # issue name
symbol=1xETH                # Reflector.symbol() with unset peg
decimals=18                 # ETH peg decimals
supply=1000000000000000000000000000

# Vanity-mining inputs — TODO: re-mine. The variant below is stale;
# changing name/supply changes argshash, so it must be re-mined anyway.
mask=0xfffff00000000000000000000000000000000fff
target=0xb175400000000000000000000000000000000e74

variant=0x0000000000000000000000000000000000000000000000000000000010f55c3f

source "$(git rev-parse --show-toplevel)/io/predictReflection.sh"
