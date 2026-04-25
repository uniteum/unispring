source .env
salt=0x0000000000000000000000000000000000000000000000000000000000000000
bytecode=$(forge inspect Unispring bytecode)
constructorArgs=$(cast abi-encode "constructor(address)" $Fountain)
initcode=$(cast concat-hex $bytecode $constructorArgs)
FountainInput=$(cast concat-hex $salt $initcode)
printf '%s' "$FountainInput" > io/Unispring.txt
Unispring=$(cast create2 --deployer $ARACHNID --salt $salt --init-code $initcode)
echo "Unispring deployed at: $Unispring"
forge verify-contract $Unispring Unispring --verifier etherscan --show-standard-json-input | jq '.'> io/Unispring.json
