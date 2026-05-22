#!/usr/bin/env bash
clone=UniteumDollar
deployer=0x1Eb8dF6040A67025C2aF9a82aB966CCd7bF1e300 # Lepton
maker=0x05dD50aD3A40629E62635Ea67Dd17C6a0a3cb388 # USDCReflector
name="Uniteum Dollar"
symbol=1xUSDC
decimals=6
supply=1000000000000000 # 1e15

mask=0xfffff0000000000000000000000000000000ffff
target=0x1111100000000000000000000000000000001C5D

variant=0x00000000000000000000000000000000000000000000000000000024de9b4201

source "$(git rev-parse --show-toplevel)/io/predictReflection.sh"
