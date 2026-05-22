#!/usr/bin/env bash
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

clone=UniteumEther
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300 # Lepton
maker=0xBDbd6217ADFe1f3AE9fd4eC4D82d62A3a9baE090 # EthReflector
name="Uniteum Ether"
symbol=1xETH
decimals=18
supply=1000000000000000000000000000 # 1e27

mask=0xfffff00000000000000000000000000000000fff
target=0x1111100000000000000000000000000000000e74

variant=0x0000000000000000000000000000000000000000000000000000000076edb882

clone_predict UniteumEther "$deployer" \
    "address,string,string,uint8,uint256" "$maker" "$name" "$symbol" "$decimals" "$supply" \
    $variant
