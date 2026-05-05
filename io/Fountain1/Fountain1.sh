#!/usr/bin/env bash
# Fountain1 — Bitsy clone of Fountain. The placer that Mimicry uses to
# seat every mimic-token V4 position.
#
# The Fountain prototype's make(address owner, uint256 variant) computes
#   salt = keccak(abi.encode(owner)) ^ variant
# so the args being hashed are just `owner` (an address).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

# Same-repo dep — Fountain prototype. Re-run io/Fountain/Fountain.sh
# first, then update this address.
Fountain=0xf00fd448443a7d1982cdE29909627217F132E080

# Owner of this clone (passed to make(); seats positions on its behalf).
owner=0xff966FE50802B74B538D2c6311Fc0201014AA294

# Vanity-mining inputs (re-mine after Fountain proto changes — the
# EIP-1167 initcode-hash depends on the proto address, so previously
# mined variants no longer hit the target).
mask=0xfff000000000000000000000000000000000ffff
target=0xf11000000000000000000000000000000000e080

clone_predict Fountain1 "$Fountain" \
    "address" "$owner" \
    0x00000000000000000000000000000000000000000000000000000000bed03a06
