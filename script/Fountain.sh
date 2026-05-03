source .env
mkdir -p io/Fountain
salt=0x00000000000000000000000000000000000000000000000000000001c8688910
bytecode=$(forge inspect Fountain bytecode)
constructorArgs=$(cast abi-encode "constructor(address)" $PoolManagerLookup)
initcode=$(cast concat-hex $bytecode $constructorArgs)
initcodehash=$(cast keccak "$initcode")
echo "initcodehash=$initcodehash"
input=$(cast concat-hex $salt $initcode)
printf '%s' "$input" > io/Fountain/$home.txt
home=$(cast create2 --deployer $deployer --salt $salt --init-code $initcode)
echo "home=$home"

mkdir -p io/Fountain
printf '%s' "$input" > "io/Fountain/$home.txt"
forge verify-contract $home Fountain --verifier etherscan --show-standard-json-input | jq '.'> io/Fountain/$home.json
