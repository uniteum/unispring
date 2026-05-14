#!/usr/bin/env bash
# Fountain — Bitsy V4 position holder, deployed via Nick.
# Cross-repo dep: PoolManagerLookup from uniswap-lookup/io/PoolManagerLookup/.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

PoolManagerLookup=0xb001d1Bb3904C5881d5b008Bf7063b0E61eBe300
owner=0x9891e323517761F525e55817F1b3fa2C52620b78
mask=0xfff000000000000000000000000000000000ffff
target=0xf00000000000000000000000000000000000e090
proto_predict Fountain 0x0000000000000000000000000000000000000000000000000000000001762468 \
    "constructor(address,address)" "$owner" "$PoolManagerLookup"
