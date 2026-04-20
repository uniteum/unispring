#!/usr/bin/env bash
# Mine a salt that gives a Lepton-minted token a vanity address.
#
# Usage: ./script/mine-salt.sh --lepton <addr> --maker <addr> --name <str> --symbol <str> --decimals <u8> --supply <u256> --mask <20-byte hex> --match <20-byte hex> [saltminer flags...]
#
# Example: ./script/mine-salt.sh --lepton 0xE5c44386F56eD35f1Dbeed0f457424DEb741F06c --maker 0xC6e6ca13983A28c15A1eCF05F9bf610A92ad6222 --name Foo --symbol BAR --decimals 18 --supply 1000000000000000000000000 --mask 0xffff00000000000000000000000000000000ffff --match 0xffff000000000000000000000000000000000001
#
# Remaining flags are forwarded to saltminer (e.g. --min, --max, --shard, --device).

set -euo pipefail

lepton=
maker=
name=
symbol=
decimals=
supply=
mask=
match=
rest=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --lepton)   lepton=$2;   shift 2 ;;
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

: "${lepton:?--lepton required}"
: "${maker:?--maker required}"
: "${name:?--name required}"
: "${symbol:?--symbol required}"
: "${decimals:?--decimals required}"
: "${supply:?--supply required}"
: "${mask:?--mask required}"
: "${match:?--match required}"

# EIP-1167 proxy initcode keyed to the Lepton proto.
initcode_hash=$(cast keccak \
  "0x3d602d80600a3d3981f3363d3d373d3d3d363d73${lepton#0x}5af43d82803e903d91602b57fd5bf3")

# Lepton XORs this hash with the user-supplied salt to form the CREATE2 salt.
args_hash=$(cast keccak "$(cast abi-encode \
  "f(address,string,string,uint8,uint256)" \
  "$maker" "$name" "$symbol" "$decimals" "$supply")")

echo "deployer      = $lepton"
echo "initcode_hash = $initcode_hash"
echo "args_hash     = $args_hash"
echo

exec saltminer \
  --deployer      "$lepton" \
  --initcode-hash "$initcode_hash" \
  --args-hash     "$args_hash" \
  --mask          "$mask" \
  --match         "$match" \
  "${rest[@]}"
