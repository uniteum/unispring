#!/usr/bin/env bash
# UniteumEther — a Reflector issue: the ERC-20 named "Uniteum Ether" minted by
# Reflector.issue("Uniteum Ether", variant). With peg unset (zero address)
# the Reflector prototype itself issues 1xETH; it issues through its
# coinage (the Lepton prototype), so this is a Lepton clone whose
# maker is the Reflector prototype and whose symbol/decimals/supply
# are fixed by Reflector for the ETH peg. The same prediction holds
# on every chain.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

# Lepton prototype — Reflector.coinage, the ICoinage that issue() calls.
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300

# msg.sender of coinage.make inside Reflector.issue is the Reflector
# prototype itself (peg is unset, so no Reflector clone is involved);
# Lepton records it as `maker` in the salt.
maker=0xBDbd6217ADFe1f3AE9fd4eC4D82d62A3a9baE090
name="Uniteum Ether"            # issue name
symbol=1xETH                # Reflector.symbol() with unset peg
decimals=18                 # ETH peg decimals
supply=1000000000000000000000000000

# Vanity-mining inputs — TODO: re-mine. The variant below is stale;
# changing name/supply changes argshash, so it must be re-mined anyway.
mask=0xfffff00000000000000000000000000000000fff
target=0x1111100000000000000000000000000000000e74

clone_predict UniteumEther "$deployer" \
    "address,string,string,uint8,uint256" "$maker" "$name" "$symbol" "$decimals" "$supply" \
    0x0000000000000000000000000000000000000000000000000000000076edb882
