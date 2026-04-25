source .env
salt=0x0000000000000000000000000000000000000000000000000000000000000000
bytecode=$(forge inspect Mimicoinage bytecode)
constructorArgs=$(cast abi-encode "constructor(address,address)" $Fountain $ICoinage)
MimicoinageInput=$(cast concat-hex $salt $bytecode $constructorArgs)
printf '%s' "$MimicoinageInput" > io/Mimicoinage.txt
Mimicoinage=$(cast call $ARACHNID $MimicoinageInput -r 11155111)
echo "Mimicoinage deployed at: $Mimicoinage"
forge verify-contract $Mimicoinage Mimicoinage --verifier etherscan --show-standard-json-input | jq '.'> io/Mimicoinage.json
