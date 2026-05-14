#!/usr/bin/env bash
# Reflector — Bitsy 1:1 mirror prototype, deployed via Nick.
# Constructor deps (hardcoded with provenance — update after re-running
# any upstream predict script):
#   Fountain1     ← unispring/io/Fountain1/  (same repo, Fountain clone)
#   ICoinage      ← lepton/io/Lepton/        (the Lepton prototype)
#   GasNameLookup ← uniswap-lookup/io/GasNameLookup/
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

Fountain=0xf006F226d2be726A2Ad2B011719BdeFDDa1EE090
ICoinage=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300
GasNameLookup=0x6A59a7229Bb59Ae5e474854382C90d891972E300

# Vanity-mining inputs. The `e080` suffix rhymes with Fountain1's
# address. Re-mine with the initcodehash that proto_predict prints.
mask=0xffff00000000000000000000000000000000ffff
target=0xbdbd00000000000000000000000000000000e090

proto_predict Reflector 0x000000000000000000000000000000000000000000000000000000004528aa2a \
    "constructor(address,address,address)" \
    "$Fountain" "$ICoinage" "$GasNameLookup"
