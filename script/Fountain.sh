source .env
salt=0x0000000000000000000000000000000000000000000000000000000000000000
bytecode=$(forge inspect Fountain bytecode)
constructorArgs=$(cast abi-encode "constructor(address)" $PoolManagerLookup)
initcode=$(cast concat-hex $bytecode $constructorArgs)
FountainInput=$(cast concat-hex $salt $initcode)
printf '%s' "$FountainInput" > io/Fountain.txt
Fountain=$(cast create2 --deployer $ARACHNID --salt $salt --init-code $initcode)
echo "Fountain deployed at: $Fountain"
forge verify-contract $Fountain Fountain --verifier etherscan --show-standard-json-input | jq '.'> io/Fountain.json
