#!/usr/bin/env bash
# Mine a salt that gives an ICoinage-minted token a vanity address.
#
# Flags default to matching env vars (Solidity-identifier naming), so `source .env` first and override only what you need.
#
# Usage: ./script/mine-icoinage-salt.sh [--icoinage <addr>] [--maker <addr>] [--name <str>] [--symbol <str>] [--decimals <u8>] [--supply <u256>] [--mask <20-byte hex>] [--match <20-byte hex>] [saltminer flags...]
#
# Env defaults: ICoinage, Maker, Name, Symbol, Decimals, Supply, SaltMask, SaltMatch
#
# Example: source .env && ./script/mine-icoinage-salt.sh --maker 0xC6e6ca13983A28c15A1eCF05F9bf610A92ad6222 --name Foo --symbol BAR --decimals 18 --supply 1000000000000000000000000 --mask 0xffff00000000000000000000000000000000ffff --match 0xffff000000000000000000000000000000000001
#
# Remaining flags are forwarded to saltminer (e.g. --min, --max, --shard, --device).

set -euo pipefail

icoinage=${ICoinage:-}
maker=${Maker:-}
name=${Name:-}
symbol=${Symbol:-}
decimals=${Decimals:-}
supply=${Supply:-}
mask=${SaltMask:-}
match=${SaltMatch:-}
rest=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --icoinage) icoinage=$2; shift 2 ;;
    --maker)    maker=$2;    shift 2 ;;
    --name)     name=$2;     shift 2 ;;
    --symbol)   symbol=$2;   shift 2 ;;
    --decimals) decimals=$2; shift 2 ;;
    --supply)   supply=$2;   shift 2 ;;
    --mask)     mask=$2;     shift 2 ;;
    --match)    match=$2;    shift 2 ;;
    *) rest+=("$1"); shift ;;
  esac
done

: "${icoinage:?set --icoinage or ICoinage}"
: "${maker:?set --maker or Maker}"
: "${name:?set --name or Name}"
: "${symbol:?set --symbol or Symbol}"
: "${decimals:?set --decimals or Decimals}"
: "${supply:?set --supply or Supply}"
: "${mask:?set --mask or SaltMask}"
: "${match:?set --match or SaltMatch}"

# EIP-1167 proxy initcode keyed to the ICoinage proto.
initcode_hash=$(cast keccak \
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73${icoinage#0x}5af43d82803e903d91602b57fd5bf3")

# ICoinage XORs this hash with the user-supplied salt to form the CREATE2 salt.
args_hash=$(cast keccak "$(cast abi-encode \
  "f(address,string,string,uint8,uint256)" \
  "$maker" "$name" "$symbol" "$decimals" "$supply")")

echo "deployer      = $icoinage"
echo "initcode_hash = $initcode_hash"
echo "args_hash     = $args_hash"
echo

exec saltminer \
  --deployer      "$icoinage" \
  --initcode-hash "$initcode_hash" \
  --args-hash     "$args_hash" \
  --mask          "$mask" \
  --match         "$match" \
  "${rest[@]}"
