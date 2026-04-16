// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
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
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title Unispring
 * @notice Fair-launch pool seeder on Uniswap V4 — permanent liquidity, built-in
 *         price floor, hub-paired spokes. Zero-fee pools.
 * @dev    See README.md for the full design rationale. The hub token is supplied
 *         externally at construction; its ETH pool is seeded single-sided by
 *         {seedHub}. Additional tokens are paired against the hub by {addSpoke}.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Unispring is IUnlockCallback {
    /**
     * @dev Discriminator for the unlock callback payload.
     */
    enum Action {
        SEED,
        BUY_HUB
    }

    /**
     * @dev Internal payload used to seed a single-sided position. `currency0Sided`
     *      selects which side of the pair the supply funds: `true` for every
     *      {addSpoke}-created pool, `false` for the {seedHub}-created hub pool.
     */
    struct SeedData {
        PoolKey key;
        uint256 supply;
        int24 tickLower;
        int24 tickUpper;
        bool currency0Sided;
    }

    /**
     * @dev Internal payload for the hub bootstrap swap.
     */
    struct BuyHubData {
        address recipient;
        uint256 amountIn;
    }

    /**
     * @notice Pool fee, in hundredths of a bip. Set to zero: Unispring creates
     *         zero-fee pools. No fees accrue to the position and there is no
     *         compounding mechanism.
     */
    uint24 public constant FEE = 0;

    /**
     * @notice Tick spacing — maximum granularity at the floor.
     */
    int24 public constant TICK_SPACING = 1;

    /**
     * @notice The Uniswap V4 PoolManager, resolved from the `IAddressLookup`
     *         supplied at construction.
     */
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice The hub token, supplied at construction.
     * @dev    Must have its full intended pool supply transferred to this contract
     *         before {seedHub} is called; {seedHub} reads `HUB.balanceOf(this)` as
     *         the amount to seed. Deploy scripts salt-mine the hub's address so
     *         it has many leading `f` bytes, which makes future {addSpoke} calls
     *         succeed with spoke tokens whose addresses sort strictly below `HUB`.
     */
    address public immutable HUB;

    /**
     * @notice Emitted when a pool is initialized, paired against the hub, and seeded.
     * @param seeder    The address that called {addSpoke} or {seedHub}.
     * @param token     The spoke token (or the hub, for {seedHub}).
     * @param poolId    The Uniswap V4 pool id.
     * @param supply    The fixed supply seeded into the pool.
     * @param tickLower Lower tick of the seeded position.
     * @param tickUpper Upper tick of the seeded position.
     */
    event Seeded(
        address indexed seeder,
        IERC20 indexed token,
        PoolId indexed poolId,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper
    );

    /**
     * @notice Thrown when `tick` is not a multiple of {TICK_SPACING}.
     */
    error TickMisaligned(int24 tick);

    /**
     * @notice Thrown when `tick` is not strictly inside `(MIN_TICK, MAX_TICK)`.
     */
    error TickOutOfRange(int24 tick);

    /**
     * @notice Thrown when `tickLower` is not strictly below `tickUpper`.
     */
    error TickLowerNotBelowUpper(int24 tickLower, int24 tickUpper);

    /**
     * @notice Thrown when the spoke token does not sort strictly below {HUB}.
     * @dev    {addSpoke} requires `token < HUB` so the spoke becomes `currency0`
     *         of the pool. This is the only currency ordering under which a
     *         single-sided seed position is both active at spot and requires
     *         zero hub capital; see README.md for the full derivation. Mine a
     *         different spoke salt until the deterministic address sorts below
     *         {HUB}.
     */
    error SpokeMustSortBelowHub(address token);

    /**
     * @notice Thrown when {unlockCallback} is invoked by anyone other than the PoolManager.
     */
    error InvalidUnlockCaller();

    /**
     * @notice Thrown if liquidity computed from supply exceeds `uint128`.
     */
    error LiquidityOverflow();

    /**
     * @notice Construct the Unispring seeder bound to an externally-supplied hub.
     * @dev    The hub pool is NOT seeded here. A contract cannot receive callbacks
     *         during its own construction (its runtime code isn't deployed yet),
     *         so pool seeding is deferred to {seedHub}.
     * @param  poolManagerLookup `IAddressLookup` resolving the chain-local
     *                       Uniswap V4 PoolManager. Dereferenced once in the
     *                       constructor and stored as {POOL_MANAGER}.
     * @param  hub           The hub token. Stored as {HUB}.
     */
    constructor(IAddressLookup poolManagerLookup, IERC20 hub) {
        POOL_MANAGER = IPoolManager(poolManagerLookup.value());
        HUB = address(hub);
    }

    /**
     * @notice Initialize the hub's ETH pool and seed it single-sided with the
     *         hub balance currently held by this contract. Callable exactly once.
     * @dev    Permissionless — any caller may trigger it. The deploy script
     *         transfers the full hub supply to this contract and then calls
     *         this immediately. Subsequent calls revert via the PoolManager's
     *         `PoolAlreadyInitialized` error. The seed is the fencepost
     *         "mirror" case (single-sided currency1 at the upper boundary,
     *         inactive at spot until the first ETH→HUB swap crosses the
     *         boundary downward). A bootstrap swap is expected right after
     *         this call so the pool shows as active to quoters and hosted
     *         front-ends.
     * @param  tickLower Lower tick of the hub position. Must be a multiple of
     *                   {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     * @param  tickUpper Upper tick of the hub position, equal to the negated
     *                   hub-priced-in-ETH price floor. Must be a multiple of
     *                   {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     * @return poolId The pool id of the newly seeded hub pool.
     */
    function seedHub(int24 tickLower, int24 tickUpper) external returns (PoolId poolId) {
        _requireValidTickRange(tickLower, tickUpper);

        uint256 supply = IERC20(HUB).balanceOf(address(this));

        PoolKey memory key = _poolKey(address(0));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        poolId = key.toId();

        IPoolManager pm = POOL_MANAGER;
        pm.initialize(key, sqrtPriceX96);
        pm.unlock(
            abi.encode(
                Action.SEED,
                abi.encode(
                    SeedData({
                        key: key, supply: supply, tickLower: tickLower, tickUpper: tickUpper, currency0Sided: false
                    })
                )
            )
        );

        emit Seeded(msg.sender, IERC20(HUB), poolId, supply, tickLower, tickUpper);
    }

    /**
     * @notice Pair an already-deployed token against the hub and lock `supply`
     *         into a single-sided V4 position with a permanent floor.
     * @dev    The spoke token must sort strictly below {HUB} so that it becomes
     *         `currency0` of the pool. Caller must approve this contract to pull
     *         `supply` tokens; the pulled balance is then locked into the seed
     *         position.
     *
     *         Permissionless by design: anyone can pair any ERC-20 against the
     *         hub. A misbehaving or malicious spoke (fee-on-transfer, rebasing,
     *         blacklisting, revert-on-transfer, ERC777-style transfer hooks)
     *         can only damage its own pool, never the hub or other spokes:
     *
     *           1. Per-pool isolation. Unispring only runs a spoke's code
     *              during operations on that spoke's own pool.
     *           2. Reentrancy via transfer hooks is blocked by Uniswap V4's
     *              single-locker model. A hook cannot re-enter {addSpoke} /
     *              {seedHub} / {buyHub} (each calls `POOL_MANAGER.unlock`,
     *              which reverts on nested entry), and it cannot call the
     *              PoolManager directly because `swap` / `modifyLiquidity`
     *              require the caller to be the active locker.
     *           3. Fee-on-transfer or revert-on-transfer causes {_seed}'s
     *              `settle` step to underpay or revert, unwinding the whole
     *              seed atomically. No partial state.
     * @param  token     The spoke token to pair against the hub.
     * @param  supply    Amount of `token` to pull from the caller and seed into
     *                   the position.
     * @param  tickLower Lower tick (price floor in spoke-in-hub semantics).
     *                   Must be a multiple of {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     * @param  tickUpper Upper tick of the spoke position. Must be a multiple of
     *                   {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     * @return poolId    The Uniswap V4 pool id.
     */
    function addSpoke(IERC20 token, uint256 supply, int24 tickLower, int24 tickUpper) external returns (PoolId poolId) {
        _requireValidTickRange(tickLower, tickUpper);

        // 1. Enforce currency0 ordering: spoke must sort strictly below the hub.
        if (address(token) >= HUB) revert SpokeMustSortBelowHub(address(token));

        // 2. Pull the seed supply from the caller.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(msg.sender, address(this), supply);

        // 3. Build the pool key. Spoke is currency0; floor on token-in-hub price
        //    equals floor on pool tick. Pool price seeded at the lower bound;
        //    the position is single-sided in currency0 and active.
        PoolKey memory key = _poolKey(address(token));
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickLower);

        poolId = key.toId();

        // 4. Initialize the pool and seed the position via the unlock callback.
        IPoolManager pm = POOL_MANAGER;
        pm.initialize(key, sqrtPriceX96);
        pm.unlock(
            abi.encode(
                Action.SEED,
                abi.encode(
                    SeedData({
                        key: key, supply: supply, tickLower: tickLower, tickUpper: tickUpper, currency0Sided: true
                    })
                )
            )
        );

        emit Seeded(msg.sender, token, poolId, supply, tickLower, tickUpper);
    }

    /**
     * @notice Buy hub tokens with native ETH via an exact-input swap on the hub
     *         pool. Intended as the bootstrap call immediately after {seedHub} to
     *         cross the upper tick downward and activate the pool for quoters.
     * @dev    Permissionless. The received HUB tokens are forwarded to `msg.sender`.
     */
    function buyHub() external payable {
        POOL_MANAGER.unlock(
            abi.encode(Action.BUY_HUB, abi.encode(BuyHubData({recipient: msg.sender, amountIn: msg.value})))
        );
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidUnlockCaller();
        IPoolManager pm = POOL_MANAGER;

        (Action action, bytes memory inner) = abi.decode(data, (Action, bytes));
        if (action == Action.SEED) {
            _seed(pm, abi.decode(inner, (SeedData)));
        } else {
            _buyHub(pm, abi.decode(inner, (BuyHubData)));
        }
        return "";
    }

    /**
     * @dev Seed a single-sided position with `supply` tokens. `currency0Sided`
     *      selects which side of the pair the supply funds.
     */
    function _seed(IPoolManager pm, SeedData memory cb) private {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cb.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cb.tickUpper);
        uint128 liquidity = cb.currency0Sided
            ? _liquidity0(sqrtLower, sqrtUpper, cb.supply)
            : _liquidity1(sqrtLower, sqrtUpper, cb.supply);

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

        // The position is single-sided, so only the funded side is owed.
        // That amount is non-positive (a debit owed by the caller); negation fits in uint128.
        Currency currency = cb.currency0Sided ? cb.key.currency0 : cb.key.currency1;
        int128 amount = cb.currency0Sided ? delta.amount0() : delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount));

        pm.sync(currency);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(Currency.unwrap(currency)).transfer(address(pm), owed);
        pm.settle();
    }

    /**
     * @dev Execute an exact-input ETH → HUB swap and forward received HUB to the
     *      recipient. Called inside `unlockCallback`.
     */
    function _buyHub(IPoolManager pm, BuyHubData memory cb) private {
        PoolKey memory key = _poolKey(address(0));

        BalanceDelta delta = pm.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(cb.amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // We owe currency0 (ETH) and are owed currency1 (HUB).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 paid = uint256(uint128(-delta.amount0()));
        pm.settle{value: paid}();

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 received = uint256(uint128(delta.amount1()));
        pm.take(key.currency1, cb.recipient, received);
    }

    /**
     * @dev Revert unless `tick` is a multiple of {TICK_SPACING} and
     *      strictly inside `(MIN_TICK, MAX_TICK)`.
     */
    function _requireValidTick(int24 tick) private pure {
        if (tick % TICK_SPACING != 0) revert TickMisaligned(tick);
        if (tick <= TickMath.MIN_TICK || tick >= TickMath.MAX_TICK) {
            revert TickOutOfRange(tick);
        }
    }

    function _requireValidTickRange(int24 tickLower, int24 tickUpper) private pure {
        _requireValidTick(tickLower);
        _requireValidTick(tickUpper);
        if (tickLower >= tickUpper) revert TickLowerNotBelowUpper(tickLower, tickUpper);
    }

    /**
     * @dev Build a pool key with the given currency0 paired against HUB.
     *      Pass `address(0)` for the hub pool (ETH/HUB), or a spoke token
     *      address for a spoke pool. Caller must ensure `currency0 < HUB`.
     */
    function _poolKey(address currency0) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(HUB),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /**
     * @dev Liquidity for a single-sided position in currency0.
     *      L = amount0 * (sqrtLower * sqrtUpper / Q96) / (sqrtUpper - sqrtLower)
     */
    function _liquidity0(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount0) private pure returns (uint128) {
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtLower), uint256(sqrtUpper), FixedPoint96.Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, uint256(sqrtUpper - sqrtLower)));
    }

    /**
     * @dev Liquidity for a single-sided position in currency1.
     *      L = amount1 * Q96 / (sqrtUpper - sqrtLower)
     */
    function _liquidity1(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1) private pure returns (uint128) {
        return _toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, uint256(sqrtUpper - sqrtLower)));
    }

    function _toUint128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert LiquidityOverflow();
        // safe: bounds checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }
}
