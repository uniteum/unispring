source .env
zero=0x0000000000000000000000000000000000000000000000000000000000000000
MimicoinageInput=$(printf '%s' "$(cast concat-hex $zero $(forge inspect Mimicoinage bytecode) $(cast abi-encode "constructor(address,address)" $Fountain $ICoinage))")
echo "$MimicoinageInput" > io/Mimicoinage.txt
Mimicoinage=$(cast call $ARACHNID $MimicoinageInput -r 11155111)
echo "Mimicoinage deployed at: $Mimicoinage"
forge verify-contract $Mimicoinage Mimicoinage --verifier etherscan --show-standard-json-input | jq '.'> io/Mimicoinage.json
