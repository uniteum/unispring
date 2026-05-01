source .env
salt=0xE396da99091B535B65384914B178b9264c7426da00000000000000000012019f
bytecode=$(forge inspect Mimicry bytecode)
constructorArgs=$(cast abi-encode "constructor(address,address)" $Fountain $ICoinage)
initcode=$(cast concat-hex $bytecode $constructorArgs)
input=$(cast concat-hex $salt $initcode)
printf '%s' "$input" > script/Mimicry.txt
initcodehash=$(cast keccak $initcode)
echo "initcodehash=$initcodehash"
Mimicry=$(cast create2 --deployer $deployer --salt $salt --init-code $initcode)
echo "Mimicry=$Mimicry"
forge verify-contract $Mimicry Mimicry --verifier etherscan --show-standard-json-input | jq '.'> script/Mimicry.json
