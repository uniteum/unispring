deployer=0x4e59b44847b379578588920cA78FbF26c0B4956C
Fountain=0xF0F1d225A78c1EdcD0f5a9E31398Ed0BA3Dee071
ICoinage=0x1EB8901612767C04b3819E8A743ADCe88F9Fe110
args=$(cast abi-encode "constructor(address,address)" $Fountain $ICoinage)
contract=Mimicry
dir=io/$contract
mkdir -p io/$contract
bytecode=$(forge inspect $contract bytecode)
initcode=$(cast concat-hex $bytecode $args)
initcodehash=$(cast keccak "$initcode")
echo "initcodehash=$initcodehash"

salt=0x00000000000000000000000000000000000000000000000000000000e31131fa
input=$(cast concat-hex $salt $initcode)
home=$(cast create2 --deployer $deployer --salt $salt --init-code $initcode)
echo "$contract=$home"

printf '%s' "$input" > $dir/$home.txt
forge verify-contract $home $contract --verifier etherscan --show-standard-json-input | jq '.'> $dir/$home.json
