// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {NeutrinoSource} from "../src/NeutrinoSource.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Launch a NeutrinoSource hub via {NeutrinoSource.make}.
 * @dev    Env vars (from .env):
 *           NeutrinoSourceProto — deployed NeutrinoSource prototype (required)
 *           HubName             — hub token name (required)
 *           HubSymbol           — hub token symbol (required)
 *           HubDecimals         — hub token decimals (required)
 *           HubSupply           — hub token supply in smallest unit (required)
 *           HubTickLower        — lower tick for the hub's ETH pool (required)
 *           HubTickUpper        — upper tick for the hub's ETH pool (required)
 *           HubSalt             — Coinage salt for the hub token (required)
 *
 *         Usage:
 * forge script script/MakeNeutrinoSource.s.sol -f $chain --private-key $tx_key --broadcast
 */
contract MakeNeutrinoSource is Script {
    function run() external {
        NeutrinoSource proto = NeutrinoSource(vm.envAddress("NeutrinoSourceProto"));
        string memory name = vm.envString("HubName");
        string memory symbol = vm.envString("HubSymbol");
        uint8 decimals = uint8(vm.envUint("HubDecimals"));
        uint256 supply = vm.envUint("HubSupply");
        int24 tickLower = int24(vm.envInt("HubTickLower"));
        int24 tickUpper = int24(vm.envInt("HubTickUpper"));
        bytes32 salt = vm.envBytes32("HubSalt");

        console2.log("NeutrinoSourceProto :", address(proto));
        console2.log("name                :", name);
        console2.log("symbol              :", symbol);
        console2.log("decimals            :", decimals);
        console2.log("supply              :", supply);
        console2.log("tickLower           :", int256(tickLower));
        console2.log("tickUpper           :", int256(tickUpper));
        console2.log("salt                :", uint256(salt));

        vm.startBroadcast();
        NeutrinoSource clone = proto.make(name, symbol, decimals, supply, tickLower, tickUpper, salt);
        vm.stopBroadcast();

        console2.log("NeutrinoSource clone:", address(clone));
        console2.log("hub                 :", address(clone.hub()));
    }
}
