// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
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

        PoolKey memory hubKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(unispring.hub()),
            fee: unispring.FEE(),
            tickSpacing: unispring.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        console2.log("hub pool id     :", uint256(PoolId.unwrap(hubKey.toId())));
        console2.log("bootstrap value :", amountIn);

        vm.startBroadcast();
        unispring.buyHub{value: amountIn}();
        vm.stopBroadcast();

        console2.log("bootstrap complete - hub pool should now be active at spot");
    }
}
