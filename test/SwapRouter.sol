// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "ierc20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title SwapRouter
 * @notice Minimal test-only router. Test personas approve this contract and
 *         call {exactInput}; the router performs the PoolManager unlock dance
 *         (swap, sync/settle on owed side, take on received side) and forwards
 *         the output to `recipient`. Keeps all V4 plumbing out of the personas
 *         and the test contract.
 */
contract SwapRouter is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    error InvalidUnlockCaller();

    struct Callback {
        address payer;
        address recipient;
        PoolKey key;
        SwapParams params;
    }

    constructor(IPoolManager poolManager) {
        POOL_MANAGER = poolManager;
    }

    /**
     * @notice Perform an exact-input swap on behalf of `msg.sender`, pulling
     *         input via {IERC20-transferFrom} and pushing output to
     *         `recipient`. The caller must have approved this router for at
     *         least `amountIn` of the input currency.
     * @param  key        Pool to swap against.
     * @param  zeroForOne Direction — true spends currency0, receives currency1.
     * @param  amountIn   Exact input amount.
     * @param  recipient  Address that receives the output currency.
     * @return amountOut  Output amount taken from the pool.
     */
    function exactInput(PoolKey calldata key, bool zeroForOne, uint128 amountIn, address recipient)
        external
        returns (uint256 amountOut)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            // forge-lint: disable-next-line(unsafe-typecast)
            amountSpecified: -int256(uint256(amountIn)),
            sqrtPriceLimitX96: limit
        });
        bytes memory ret = POOL_MANAGER.unlock(
            abi.encode(Callback({payer: msg.sender, recipient: recipient, key: key, params: params}))
        );
        BalanceDelta delta = abi.decode(ret, (BalanceDelta));
        // forge-lint: disable-next-line(unsafe-typecast)
        amountOut = zeroForOne ? uint256(uint128(delta.amount1())) : uint256(uint128(delta.amount0()));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidUnlockCaller();
        Callback memory cb = abi.decode(data, (Callback));

        BalanceDelta delta = POOL_MANAGER.swap(cb.key, cb.params, "");
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();

        // forge-lint: disable-next-line(unsafe-typecast)
        if (a0 < 0) _pay(cb.key.currency0, cb.payer, uint256(uint128(-a0)));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a1 < 0) _pay(cb.key.currency1, cb.payer, uint256(uint128(-a1)));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a0 > 0) POOL_MANAGER.take(cb.key.currency0, cb.recipient, uint256(uint128(a0)));
        // forge-lint: disable-next-line(unsafe-typecast)
        if (a1 > 0) POOL_MANAGER.take(cb.key.currency1, cb.recipient, uint256(uint128(a1)));

        return abi.encode(delta);
    }

    /**
     * @dev Pull `owed` of `currency` from `payer` and settle to the PoolManager.
     *      `payer` must have approved this router for at least `owed`.
     */
    function _pay(Currency currency, address payer, uint256 owed) private {
        POOL_MANAGER.sync(currency);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(Currency.unwrap(currency)).transferFrom(payer, address(POOL_MANAGER), owed);
        POOL_MANAGER.settle();
    }
}
