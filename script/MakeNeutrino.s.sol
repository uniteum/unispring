// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Neutrino} from "../src/Neutrino.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Launch a Neutrino hub via {Neutrino.make}.
 * @dev    Env vars (from .env):
 *           NeutrinoProto — deployed Neutrino prototype (required)
 *           HubName       — hub token name (required)
 *           HubSymbol     — hub token symbol (required)
 *           HubSupply     — hub token supply in wei (required)
 *           HubTickLower  — lower tick for the hub's ETH pool (required)
 *           HubTickUpper  — upper tick for the hub's ETH pool (required)
 *           HubSalt       — Lepton salt for the hub token (required)
 *
 *         Usage:
 * forge script script/MakeNeutrino.s.sol -f $chain --private-key $tx_key --broadcast
 */
contract MakeNeutrino is Script {
    function run() external {
        Neutrino proto = Neutrino(vm.envAddress("NeutrinoProto"));
        string memory name = vm.envString("HubName");
        string memory symbol = vm.envString("HubSymbol");
        uint256 supply = vm.envUint("HubSupply");
        int24 tickLower = int24(vm.envInt("HubTickLower"));
        int24 tickUpper = int24(vm.envInt("HubTickUpper"));
        bytes32 salt = vm.envBytes32("HubSalt");

        console2.log("NeutrinoProto :", address(proto));
        console2.log("name          :", name);
        console2.log("symbol        :", symbol);
        console2.log("supply        :", supply);
        console2.log("tickLower     :", int256(tickLower));
        console2.log("tickUpper     :", int256(tickUpper));
        console2.log("salt          :", uint256(salt));

        vm.startBroadcast();
        Neutrino clone = proto.make(name, symbol, supply, tickLower, tickUpper, salt);
        vm.stopBroadcast();

        console2.log("Neutrino clone:", address(clone));
        console2.log("hub           :", address(clone.hub()));
    }
}
