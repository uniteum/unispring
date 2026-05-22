#!/usr/bin/env bash
clone=Dadda
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300 # Lepton
maker=0x05dD50aD3A40629E62635Ea67Dd17C6a0a3cb388 # USDCReflector
name=Dadda
symbol=1xUSDC
decimals=6
supply=1000000000000000 # 1e15

mask=0xfffff000000000000000000000000000000fffff
target=0xdadda000000000000000000000000000000dadda

variant=0x0000000000000000000000000000000000000000000000000000001f961515f9

source "$(git rev-parse --show-toplevel)/io/predictReflection.sh"
