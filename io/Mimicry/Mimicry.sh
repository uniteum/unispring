#!/usr/bin/env bash
# Mimicry — Bitsy 1:1 mirror prototype, deployed via Nick.
# Constructor deps (hardcoded with provenance — update after re-running
# any upstream predict script):
#   Fountain      ← unispring/io/Fountain/  (same repo)
#   ICoinage      ← lepton/io/Lepton/        (the Lepton prototype)
#   GasNameLookup ← uniswap-lookup/io/GasNameLookup/
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

Fountain=0x_TBD_RUN_FOUNTAIN_FIRST
ICoinage=0x1EB8901612767C04b3819E8A743ADCe88F9Fe110
GasNameLookup=0x6A58a74AFd7224a91Fa94e07C1821304de54E220

proto_predict Mimicry 0x00000000000000000000000000000000000000000000000000000000bdc7f617 \
    "constructor(address,address,address)" \
    "$Fountain" "$ICoinage" "$GasNameLookup"
