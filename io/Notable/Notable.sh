#!/usr/bin/env bash
# Notable — Bitsy 1:1 mirror prototype, deployed via Nick.
# Constructor deps (hardcoded with provenance — update after re-running
# any upstream predict script):
#   Fountain1     ← unispring/io/Fountain1/  (same repo, Fountain clone)
#   ICoinage      ← lepton/io/Lepton/        (the Lepton prototype)
#   GasNameLookup ← uniswap-lookup/io/GasNameLookup/
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

Fountain1=0xf11e17473f8D933CFC439Ef694a0285c8D19e080
ICoinage=0x1EB8901612767C04b3819E8A743ADCe88F9Fe110
GasNameLookup=0x6A58a74AFd7224a91Fa94e07C1821304de54E220

# Vanity-mining inputs. The `e080` suffix rhymes with Fountain1's
# address; the leading `3131c0` was the Mimicry-era prefix and can be
# changed for Notable. Re-mine with the initcodehash that proto_predict
# prints (Notable's bytecode differs from Mimicry's, so the legacy salt
# 0x...22e1e4954 no longer lands).
mask=0xfffff00000000000000000000000000000000fff
target=0x3131c0000000000000000000000000000000e080

proto_predict Notable 0x000000000000000000000000000000000000000000000000000000011cc5e64e \
    "constructor(address,address,address)" \
    "$Fountain1" "$ICoinage" "$GasNameLookup"
