// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {NeutrinoSource} from "../src/NeutrinoSource.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Launch a spoke token via {NeutrinoSource.launch}.
 * @dev    Env vars (from .env):
 *           HubNeutrinoSource — deployed NeutrinoSource clone for the hub (required)
 *           SpokeName         — spoke token name (required)
 *           SpokeSymbol       — spoke token symbol (required)
 *           SpokeSupply       — spoke token supply in wei (required)
 *           SpokeSalt         — Coinage salt for the spoke token (required)
 *           SpokeTickLower    — lower tick for the spoke's pool (required)
 *           SpokeTickUpper    — upper tick for the spoke's pool (required)
 *
 *         Usage:
 * forge script script/LaunchSpoke.s.sol -f $chain --private-key $tx_key --broadcast
 */
contract LaunchSpoke is Script {
    function run() external {
        NeutrinoSource source = NeutrinoSource(vm.envAddress("HubNeutrinoSource"));
        string memory name = vm.envString("SpokeName");
        string memory symbol = vm.envString("SpokeSymbol");
        uint256 supply = vm.envUint("SpokeSupply");
        bytes32 salt = vm.envBytes32("SpokeSalt");
        int24 tickLower = int24(vm.envInt("SpokeTickLower"));
        int24 tickUpper = int24(vm.envInt("SpokeTickUpper"));

        console2.log("HubNeutrinoSource :", address(source));
        console2.log("name              :", name);
        console2.log("symbol            :", symbol);
        console2.log("supply            :", supply);
        console2.log("salt              :", uint256(salt));
        console2.log("tickLower         :", int256(tickLower));
        console2.log("tickUpper         :", int256(tickUpper));

        vm.startBroadcast();
        IERC20Metadata spoke = source.launch(name, symbol, supply, salt, tickLower, tickUpper);
        vm.stopBroadcast();

        console2.log("Spoke             :", address(spoke));
    }
}
