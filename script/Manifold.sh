source .env
salt=0x0000000000000000000000000000000000000000000000000000000000000000
bytecode=$(forge inspect Manifold bytecode)
constructorArgs=$(cast abi-encode "constructor(address)" $Fountain)
initcode=$(cast concat-hex $bytecode $constructorArgs)
FountainInput=$(cast concat-hex $salt $initcode)
printf '%s' "$FountainInput" > io/Manifold.txt
Manifold=$(cast create2 --deployer $deployer --salt $salt --init-code $initcode)
echo "Manifold deployed at: $Manifold"
forge verify-contract $Manifold Manifold --verifier etherscan --show-standard-json-input | jq '.'> io/Manifold.json
