// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Script, console} from "forge-std/Script.sol";

/**
 * @notice Read-only: print slot0 and liquidity for a Unispring pool.
 * @dev    Usage: forge script script/CheckPool.s.sol -f sepolia \
 *                --sig "run(address)" 0x7E7b46b56a03ebBaa7105a1028EC9490714bf174
 */
contract CheckPool is Script {
    using StateLibrary for IPoolManager;

    Unispring constant UNISPRING = Unispring(0x72A6eA5a58B41aFEE824dF8ebF87714125f494CC);

    function run(address newToken) external view {
        address hub = UNISPRING.HUB();
        bool newIsCurrency0 = newToken < hub;

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(newIsCurrency0 ? newToken : hub),
            currency1: Currency.wrap(newIsCurrency0 ? hub : newToken),
            fee: UNISPRING.FEE(),
            tickSpacing: UNISPRING.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        PoolId id = key.toId();

        IPoolManager pm = UNISPRING.poolManager();
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
