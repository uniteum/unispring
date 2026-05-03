deployer=0xF0f08B5E12759aEAb670FBC3163230a0225ce071
initcode="0x3d602d80600a3d3981f3363d3d373d3d3d363d73${deployer#0x}5af43d82803e903d91602b57fd5bf3"
initcodehash=$(cast keccak "$initcode")
echo "initcodehash=$initcodehash"

maker=0xff966FE50802B74B538D2c6311Fc0201014AA294
argshash=$(cast keccak "$maker")
echo "argshash=$argshash"

variant=0x0000000000000000000000000000000000000000000000000000000196628b9c 
input=$(cast calldata "make(uint256)" "$variant")
# XOR argshash ^ variant (256-bit, too wide for bash arithmetic)
salt=$(python3 -c "print(f'0x{int(\"$argshash\",16) ^ int(\"$variant\",16):064x}')")
home=$(cast create2 --deployer "$deployer" --salt "$salt" --init-code "$initcode")
echo "home=$home"

mkdir -p io/Fountain1
printf '%s' "$input" > "io/Fountain1/$home.txt"
