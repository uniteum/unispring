#!/usr/bin/env bash
# Mimicry — Bitsy 1:1 mirror prototype, deployed via Nick.
# Constructor deps (hardcoded with provenance — update after re-running
# any upstream predict script):
#   Fountain1     ← unispring/io/Fountain1/  (same repo, Fountain clone)
#   ICoinage      ← lepton/io/Lepton/        (the Lepton prototype)
#   GasNameLookup ← uniswap-lookup/io/GasNameLookup/
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

Fountain1=0xf1169704621C4CEdCBbC90c9c1e87930e24ce080
ICoinage=0x1EB8901612767C04b3819E8A743ADCe88F9Fe110
GasNameLookup=0x6A58a74AFd7224a91Fa94e07C1821304de54E220
mask=0xfffff00000000000000000000000000000000fff
target=0x3131c0000000000000000000000000000000e080

proto_predict Mimicry 0x0000000000000000000000000000000000000000000000000000000248a78e76 \
    "constructor(address,address,address)" \
    "$Fountain1" "$ICoinage" "$GasNameLookup"
