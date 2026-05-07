#!/usr/bin/env bash
# Fountain1 — Bitsy clone of Fountain. The placer that Notable uses to
# seat every issue-token V4 position.
#
# The Fountain prototype's make(address owner, uint256 variant) computes
#   salt = keccak(abi.encode(owner)) ^ variant
# so the args being hashed are just `owner` (an address).
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

# Same-repo dep — Fountain prototype. Re-run io/Fountain/Fountain.sh
# first, then update this address.
Fountain=0xf0071849DD48444cf8B2b49C2B394EF1A087e080

# Owner of this clone (passed to make(); seats positions on its behalf).
owner=0x9891e323517761F525e55817F1b3fa2C52620b78

# Vanity-mining inputs (re-mine after Fountain proto changes — the
# EIP-1167 initcode-hash depends on the proto address, so previously
# mined variants no longer hit the target).
mask=0xfff000000000000000000000000000000000ffff
target=0xf11000000000000000000000000000000000e080

clone_predict Fountain1 "$Fountain" \
    "address" "$owner" \
    0x00000000000000000000000000000000000000000000000000000000c2096c43
