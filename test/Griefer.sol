// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "ierc20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Griefer
 * @notice Test persona that interacts with the PoolManager directly, used
 *         to simulate front-run-`initialize` attacks and to seat raw
 *         liquidity at chosen ranges. Holds whatever currencies the test
 *         deals to it; pays from its own balance during liquidity seating.
 */
contract Griefer is IUnlockCallback {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable POOL_MANAGER;
    string public name;

    error InvalidUnlockCaller();

    bytes32 private constant TAG_MOVE = keccak256("move");
    bytes32 private constant TAG_SEAT = keccak256("seat");

    constructor(IPoolManager poolManager, string memory name_) {
        POOL_MANAGER = poolManager;
        name = name_;
        console.log("griefer %s born %s", name_, address(this));
    }

    receive() external payable {}

    /**
     * @notice Front-run-`initialize`: set the pool's slot0 to an arbitrary
     *         price before the legitimate deployer has a chance to.
     */
    function preInit(PoolKey calldata key, uint160 sqrtPriceX96) external {
        POOL_MANAGER.initialize(key, sqrtPriceX96);
    }

    /**
     * @notice Walk the pool's price to `targetSqrtPriceX96` via a 1-wei
     *         swap. Free when the pool has no liquidity in the path
     *         (same mechanism Fountain uses to recover from grief).
     */
    function movePrice(PoolKey calldata key, uint160 targetSqrtPriceX96) external {
        POOL_MANAGER.unlock(abi.encode(TAG_MOVE, abi.encode(key, targetSqrtPriceX96)));
    }

    /**
     * @notice Seat `liquidity` at `[tickLower, tickUpper]` from this
     *         contract's balance. Test must `deal` both currencies to
     *         this contract first.
     */
    function seat(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        POOL_MANAGER.unlock(abi.encode(TAG_SEAT, abi.encode(key, tickLower, tickUpper, liquidity)));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidUnlockCaller();
        (bytes32 tag, bytes memory payload) = abi.decode(data, (bytes32, bytes));
        if (tag == TAG_MOVE) {
            (PoolKey memory key, uint160 target) = abi.decode(payload, (PoolKey, uint160));
            (uint160 cur,,,) = POOL_MANAGER.getSlot0(key.toId());
            bool zeroForOne = target < cur;
            POOL_MANAGER.swap(
                key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(1), sqrtPriceLimitX96: target}), ""
            );
        } else if (tag == TAG_SEAT) {
            (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
                abi.decode(payload, (PoolKey, int24, int24, uint128));
            (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );
            int128 a0 = delta.amount0();
            int128 a1 = delta.amount1();
            // forge-lint: disable-next-line(unsafe-typecast)
            if (a0 < 0) _pay(key.currency0, uint256(uint128(-a0)));
            // forge-lint: disable-next-line(unsafe-typecast)
            if (a1 < 0) _pay(key.currency1, uint256(uint128(-a1)));
        }
        return "";
    }

    function _pay(Currency currency, uint256 owed) private {
        POOL_MANAGER.sync(currency);
        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{value: owed}();
        } else {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), owed);
            POOL_MANAGER.settle();
        }
    }
}
