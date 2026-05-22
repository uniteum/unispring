#!/usr/bin/env bash
clone=GoodFood
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300 # Lepton
maker=0x05dD50aD3A40629E62635Ea67Dd17C6a0a3cb388 # USDCReflector
name="Good Food"
symbol=1xUSDC
decimals=6
supply=1000000000000000 # 1e15

mask=0xffff00000000000000000000000000000000ffff
target=0x600d00000000000000000000000000000000f00d

variant=0x00000000000000000000000000000000000000000000000000000000b4551d0b

source "$(git rev-parse --show-toplevel)/io/predictReflection.sh"
