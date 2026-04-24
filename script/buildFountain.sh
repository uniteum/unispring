forge script script/FountainDeploy.s.sol -f $chain
transaction=$(jq -r '.transactions[0]' broadcast/FountainDeploy.s.sol/$chain/dry-run/run-latest.json)
Fountain=$(echo "$transaction" | jq -r '.contractAddress')
forge verify-contract $Fountain Fountain --chain $chain --verifier etherscan --show-standard-json-input | jq '.'> io/Fountain.json
echo "$transaction" | jq -j '.transaction.input' > io/FountainInput.txt
