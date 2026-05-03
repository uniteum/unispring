source .env
args=$(cast abi-encode "constructor(address,address)" $Fountain $ICoinage)
contract=Mimicry
dir=io/$contract
mkdir -p io/$contract
bytecode=$(forge inspect $contract bytecode)
initcode=$(cast concat-hex $bytecode $args)
initcodehash=$(cast keccak "$initcode")
echo "initcodehash=$initcodehash"

input=$(cast concat-hex $salt $initcode)
salt=0x00000000000000000000000000000000000000000000000000000000e31131fa
home=$(cast create2 --deployer $deployer --salt $salt --init-code $initcode)
echo "$contract=$home"

printf '%s' "$input" > $dir/$home.txt
forge verify-contract $home $contract --verifier etherscan --show-standard-json-input | jq '.'> $dir/$home.json
