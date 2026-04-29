// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPoolConfig} from "../src/IPoolConfig.sol";
import {Manifold} from "../src/Manifold.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Script, console} from "forge-std/Script.sol";

/**
 * @notice Read-only: print slot0 and liquidity for a Manifold pool.
 * @dev    Usage: forge script script/CheckPool.s.sol -f $chain
 */
contract CheckPool is Script {
    using StateLibrary for IPoolManager;

    function run() external view {
        Manifold spring = Manifold(payable(vm.envAddress("Manifold")));
        IPoolConfig fountain = IPoolConfig(address(spring.placer()));
        address newToken = vm.envAddress("HelloWorld");
        address hub = spring.hub();
        bool newIsCurrency0 = newToken < hub;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(newIsCurrency0 ? newToken : hub),
            currency1: Currency.wrap(newIsCurrency0 ? hub : newToken),
            fee: fountain.fee(),
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();

        IPoolManager pm = fountain.poolManager();
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(id);
        uint128 liquidity = pm.getLiquidity(id);

        console.log("PoolManager:  ", address(pm));
        console.log("currency0:    ", Currency.unwrap(key.currency0));
        console.log("currency1:    ", Currency.unwrap(key.currency1));
        console.log("fee:          ", uint256(key.fee));
        console.log("tickSpacing:  ", int256(key.tickSpacing));
        console.log("poolId:       ", uint256(PoolId.unwrap(id)));
        console.log("sqrtPriceX96: ", uint256(sqrtPriceX96));
        console.log("tick:         ", int256(tick));
        console.log("protocolFee:  ", uint256(protocolFee));
        console.log("lpFee:        ", uint256(lpFee));
        console.log("liquidity:    ", uint256(liquidity));
    }
}
