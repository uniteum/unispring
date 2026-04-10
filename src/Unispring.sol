// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title Unispring
 * @notice Fair-launch token factory on Uniswap V4 — permanent liquidity, built-in
 *         price floor, zero maker capital, zero fees.
 * @dev    See README.md for the full design rationale. The factory is a singleton
 *         with no owner, no constructor arguments, and identical bytecode on every
 *         chain. All per-token state is keyed by V4 `PoolId`.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Unispring is IUnlockCallback {
    /**
     * @notice The Lepton ERC-20 maker used to mint each new token.
     */
    ICoinage public constant COINAGE = ICoinage(0x14AE57aEd6aC1cD48fA811ED885Ab4a4c5E28c42);

    /**
     * @notice The hub token every Unispring pool is paired against (Uniteum 1).
     */
    address public constant HUB = 0x9a24ceab8978DD106f5db4E443D481918876fD62;

    /**
     * @notice Per-chain `IAddressLookup` resolving the Uniswap V4 PoolManager.
     */
    IAddressLookup public constant POOL_MANAGER_LOOKUP = IAddressLookup(0xd6185883DD1Fa3F6F4F0b646f94D1fb46d618c23);

    /**
     * @notice Pool fee, in hundredths of a bip. Zero — no swap fee, no compounding.
     */
    uint24 public constant FEE = 0;

    /**
     * @notice Tick spacing — minimum, for maximum granularity at the floor.
     */
    int24 public constant TICK_SPACING = 1;

    /**
     * @notice The new token created by Unispring for a given pool.
     */
    mapping(PoolId => IERC20) public token;

    /**
     * @notice Emitted when a token is minted, paired against the hub, and seeded.
     * @param maker     The address that called {make}.
     * @param newToken  The freshly deployed Lepton token.
     * @param poolId    The Uniswap V4 pool id.
     * @param supply    The fixed supply minted into the pool.
     * @param tickFloor The price floor in new-token-priced-in-hub semantics.
     */
    event Made(address indexed maker, IERC20 indexed newToken, PoolId indexed poolId, uint256 supply, int24 tickFloor);

    /**
     * @notice Thrown when `tickFloor` is not a multiple of {TICK_SPACING}.
     */
    error TickFloorMisaligned(int24 tickFloor);

    /**
     * @notice Thrown when `tickFloor` is not strictly inside `(MIN_TICK, MAX_TICK)`.
     */
    error TickFloorOutOfRange(int24 tickFloor);

    /**
     * @notice Thrown when a pool with the same key has already been created.
     */
    error PoolAlreadyExists(PoolId id);

    /**
     * @notice Thrown when {unlockCallback} is invoked by anyone other than the PoolManager.
     */
    error InvalidUnlockCaller();

    /**
     * @notice Thrown if liquidity computed from supply exceeds `uint128`.
     */
    error LiquidityOverflow();

    /**
     * @dev Internal payload passed through {IPoolManager.unlock}.
     */
    struct CallbackData {
        PoolKey key;
        IERC20 newToken;
        uint256 supply;
        int24 tickLower;
        int24 tickUpper;
        bool newIsCurrency0;
    }

    /**
     * @notice Mint a fixed-supply token, pair it against the hub, and lock the
     *         entire supply into a single-sided V4 position with a permanent floor.
     * @param  name      Token name (passed through to Lepton).
     * @param  symbol    Token symbol (passed through to Lepton).
     * @param  supply    Token supply (passed through to Lepton).
     * @param  tickFloor Price floor expressed in new-token-priced-in-hub semantics.
     *                   Must be a multiple of {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     * @return newToken  The freshly deployed Lepton token.
     * @return poolId    The Uniswap V4 pool id.
     */
    function make(string calldata name, string calldata symbol, uint256 supply, int24 tickFloor)
        external
        returns (IERC20 newToken, PoolId poolId)
    {
        if (tickFloor % TICK_SPACING != 0) revert TickFloorMisaligned(tickFloor);
        if (tickFloor <= TickMath.MIN_TICK || tickFloor >= TickMath.MAX_TICK) {
            revert TickFloorOutOfRange(tickFloor);
        }

        // 1. Mint the entire fixed supply to this contract.
        newToken = IERC20(address(COINAGE.make(name, symbol, supply)));

        // 2. Determine pool currency ordering and tick range.
        bool newIsCurrency0 = address(newToken) < HUB;
        PoolKey memory key;
        int24 tickLower;
        int24 tickUpper;
        uint160 sqrtPriceX96;
        if (newIsCurrency0) {
            // newToken is currency0; floor on token-in-hub price = floor on pool tick.
            // Range [tickFloor, MAX]; pool price at lower bound; position holds only currency0.
            key = PoolKey({
                currency0: Currency.wrap(address(newToken)),
                currency1: Currency.wrap(HUB),
                fee: FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
            tickLower = tickFloor;
            tickUpper = TickMath.maxUsableTick(TICK_SPACING);
            sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickLower);
        } else {
            // newToken is currency1; floor on token-in-hub price = ceiling on pool tick (sign flipped).
            // Range [MIN, -tickFloor]; pool price at upper bound; position holds only currency1.
            key = PoolKey({
                currency0: Currency.wrap(HUB),
                currency1: Currency.wrap(address(newToken)),
                fee: FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
            tickLower = TickMath.minUsableTick(TICK_SPACING);
            tickUpper = -tickFloor;
            sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        }

        poolId = key.toId();
        if (address(token[poolId]) != address(0)) revert PoolAlreadyExists(poolId);
        token[poolId] = newToken;

        // 3. Initialize the pool and seed the position via the unlock callback.
        IPoolManager pm = poolManager();
        pm.initialize(key, sqrtPriceX96);
        pm.unlock(
            abi.encode(
                CallbackData({
                    key: key,
                    newToken: newToken,
                    supply: supply,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    newIsCurrency0: newIsCurrency0
                })
            )
        );

        emit Made(msg.sender, newToken, poolId, supply, tickFloor);
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager pm = poolManager();
        if (msg.sender != address(pm)) revert InvalidUnlockCaller();
        CallbackData memory cb = abi.decode(data, (CallbackData));

        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(cb.tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(cb.tickUpper);

        // Compute liquidity for a single-sided position holding `supply` of the new token.
        uint128 liquidity = cb.newIsCurrency0
            ? _liquidityForAmount0(sqrtPriceLowerX96, sqrtPriceUpperX96, cb.supply)
            : _liquidityForAmount1(sqrtPriceLowerX96, sqrtPriceUpperX96, cb.supply);

        (BalanceDelta delta,) = pm.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        // Settle the new token side: PoolManager is owed `-amountNew`.
        // The hub side delta is zero because the position is single-sided.
        int128 amountNew = cb.newIsCurrency0 ? delta.amount0() : delta.amount1();
        // amountNew is non-positive (a debit owed by the caller); negation fits in uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amountNew));

        Currency newCurrency = Currency.wrap(address(cb.newToken));
        pm.sync(newCurrency);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        cb.newToken.transfer(address(pm), owed);
        pm.settle();

        return "";
    }

    /**
     * @notice Resolve the chain-local Uniswap V4 PoolManager.
     */
    function poolManager() public view returns (IPoolManager) {
        return IPoolManager(POOL_MANAGER_LOOKUP.value());
    }

    /**
     * @dev Liquidity for a single-sided position in currency0.
     *      L = amount0 * (sqrtLower * sqrtUpper / Q96) / (sqrtUpper - sqrtLower)
     */
    function _liquidityForAmount0(uint160 sqrtPriceLowerX96, uint160 sqrtPriceUpperX96, uint256 amount0)
        private
        pure
        returns (uint128)
    {
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtPriceLowerX96), uint256(sqrtPriceUpperX96), FixedPoint96.Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, uint256(sqrtPriceUpperX96 - sqrtPriceLowerX96)));
    }

    /**
     * @dev Liquidity for a single-sided position in currency1.
     *      L = amount1 * Q96 / (sqrtUpper - sqrtLower)
     */
    function _liquidityForAmount1(uint160 sqrtPriceLowerX96, uint160 sqrtPriceUpperX96, uint256 amount1)
        private
        pure
        returns (uint128)
    {
        return _toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, uint256(sqrtPriceUpperX96 - sqrtPriceLowerX96)));
    }

    function _toUint128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert LiquidityOverflow();
        // safe: bounds checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }
}
