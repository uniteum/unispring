#!/usr/bin/env bash
# Fountain — Bitsy V4 position holder, deployed via Nick.
# Cross-repo dep: PoolManagerLookup from uniswap-lookup/io/PoolManagerLookup/.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

PoolManagerLookup=0xB001Ee991d31e76E0edc4073B24B0C2B7202E220
mask=0xfff000000000000000000000000000000000ffff
target=0xf00000000000000000000000000000000000e080
proto_predict Fountain 0x00000000000000000000000000000000000000000000000000000000bf4af04a \
    "constructor(address)" "$PoolManagerLookup"
