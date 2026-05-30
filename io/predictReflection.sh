#!/usr/bin/env bash
# predictReflection.sh — shared tail for io/<Issue>/<Issue>.sh scripts that
# predict a Reflector issue: a Lepton clone minted by Reflector.issue(name,
# variant) through the Lepton coinage. The caller sets the issue's vars
# (clone, deployer, maker, name, symbol, decimals, supply, variant, plus the
# optional mask/target vanity inputs) and then sources this file.
set -euo pipefail
source "$(dirname ${BASH_SOURCE})/../lib/crucible/script/clone.sh"

# The address is a Lepton coinage clone keyed by (maker, name, symbol,
# decimals, supply); on-chain it is created by maker.issue(name, variant,
# supply), so the .txt encodes that call and the yml `via` points at the maker.
clone_predict "$clone" "$deployer" \
    "address,string,string,uint8,uint256" "$maker" "$name" "$symbol" "$decimals" "$supply" \
    "$variant" \
    -- "$maker" "issue(string,uint256,uint256)" "$name" "$variant" "$supply"
