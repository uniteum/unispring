source .env
salt=0x0000000000000000000000000000000000000000000000000000000000000000
bytecode=$(forge inspect Mimicoinage bytecode)
constructorArgs=$(cast abi-encode "constructor(address,address)" $Fountain $ICoinage)
initcode=$(cast concat-hex $bytecode $constructorArgs)
MimicoinageInput=$(cast concat-hex $salt $initcode)
printf '%s' "$MimicoinageInput" > io/Mimicoinage.txt
Mimicoinage=$(cast create2 --deployer $deployer --salt $salt --init-code $initcode)
echo "Mimicoinage deployed at: $Mimicoinage"
forge verify-contract $Mimicoinage Mimicoinage --verifier etherscan --show-standard-json-input | jq '.'> io/Mimicoinage.json
