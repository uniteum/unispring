#!/usr/bin/env bash
# predictReflection.sh — shared tail for io/<Issue>/<Issue>.sh scripts that
# predict a Reflector issue: a Lepton clone minted by Reflector.issue(name,
# variant) through the Lepton coinage. The caller sets the issue's vars
# (clone, deployer, maker, name, symbol, decimals, supply, variant, plus the
# optional mask/target vanity inputs) and then sources this file.
set -euo pipefail
source "$(dirname ${BASH_SOURCE})/../lib/crucible/script/clone.sh"

clone_predict "$clone" "$deployer" \
    "address,string,string,uint8,uint256" "$maker" "$name" "$symbol" "$decimals" "$supply" \
    "$variant"
