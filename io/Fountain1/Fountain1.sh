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
Fountain=0xF000236E0D63d9f75001D440Ad2d89f4FeB0E090

# Owner of this clone (passed to make(); seats positions on its behalf).
owner=0x9891e323517761F525e55817F1b3fa2C52620b78

# Vanity-mining inputs (re-mine after Fountain proto changes — the
# EIP-1167 initcode-hash depends on the proto address, so previously
# mined variants no longer hit the target).
mask=0xfff000000000000000000000000000000000ffff
target=0xf11000000000000000000000000000000000e090

clone_predict Fountain1 "$Fountain" \
    "address" "$owner" \
    0x0000000000000000000000000000000000000000000000000000000017c9db4a
