// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {SwapRouter} from "./SwapRouter.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/console.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @title Trader
 * @notice Test persona that swaps through a {SwapRouter}. Mirrors the
 *         production shape (EOA → router → PoolManager): the persona holds
 *         tokens, approves the router, and calls {exactInput}. It knows
 *         nothing about unlock callbacks.
 * @dev    Standalone for now. When the `erc20`/`strings` submodules land
 *         and crucible's `User.sol` is compilable here, rebase onto it to
 *         pick up shared balance-logging helpers.
 */
contract Trader {
    string public name;
    SwapRouter public immutable ROUTER;

    constructor(string memory name_, SwapRouter router) {
        name = name_;
        ROUTER = router;
        console.log("%s born %s", name_, address(this));
    }

    /**
     * @notice Exact-input swap on `key`. Output is received by this trader.
     * @param  key        Pool to swap against.
     * @param  zeroForOne Direction — true spends `key.currency0`.
     * @param  amountIn   Exact input amount.
     * @return amountOut  Output amount received.
     */
    function swap(PoolKey memory key, bool zeroForOne, uint128 amountIn) public returns (uint256 amountOut) {
        Currency inCurrency = zeroForOne ? key.currency0 : key.currency1;
        IERC20 input = IERC20(Currency.unwrap(inCurrency));
        input.approve(address(ROUTER), amountIn);
        amountOut = ROUTER.exactInput(key, zeroForOne, amountIn, address(this));
    }
}
