// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Perform a single tiny ETH → HUB swap via {Unispring.buyHub} against
 *         an already-deployed Unispring instance. Flips the hub pool from the
 *         inactive-at-spot mirror state into a normal active state that hosted
 *         Uniswap front-ends will quote against.
 * @dev    Env vars:
 *           Unispring       — deployed Unispring address (required)
 *           BootstrapValue  — wei of ETH to swap, default 1 gwei (1e9).
 *
 *         Usage:
 * forge script script/BootstrapHub.s.sol:BootstrapHub -f $chain --private-key $tx_key --broadcast
 */
contract BootstrapHub is Script {
    function run() external {
        Unispring unispring = Unispring(payable(vm.envAddress("Unispring")));
        uint256 amountIn = vm.envOr("BootstrapValue", uint256(1 gwei));

        console2.log("hub pool id     :", uint256(PoolId.unwrap(unispring.hubPool())));
        console2.log("bootstrap value :", amountIn);

        vm.startBroadcast();
        unispring.buyHub{value: amountIn}();
        vm.stopBroadcast();

        console2.log("bootstrap complete - hub pool should now be active at spot");
    }
}
