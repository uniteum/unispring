source .env
zero=0x0000000000000000000000000000000000000000000000000000000000000000
printf '%s' "$(cast concat-hex $zero $(forge inspect Mimicoinage bytecode) $(cast abi-encode "constructor(address,address)" $Fountain $ICoinage))" > io/Mimicoinage.txt
