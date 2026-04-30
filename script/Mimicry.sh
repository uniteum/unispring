source .env
salt=0x0000000000000000000000000000000000000000000000000000000000000000
bytecode=$(forge inspect Mimicry bytecode)
constructorArgs=$(cast abi-encode "constructor(address,address)" $Fountain $ICoinage)
initcode=$(cast concat-hex $bytecode $constructorArgs)
input=$(cast concat-hex $salt $initcode)
printf '%s' "$input" > io/Mimicry.txt
Mimicry=$(cast create2 --deployer $deployer --salt $salt --init-code $initcode)
echo "Mimicry=$Mimicry"
forge verify-contract $Mimicry Mimicry --verifier etherscan --show-standard-json-input | jq '.'> io/Mimicry.json
