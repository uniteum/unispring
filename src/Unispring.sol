// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title Unispring
 * @notice Fair-launch pool seeder on Uniswap V4 — permanent liquidity, built-in
 *         price floor, hub-paired spokes, compounding via fee plowback.
 * @dev    See README.md for the full design rationale. The hub token is supplied
 *         externally at construction; its ETH pool is seeded single-sided by
 *         {seedHub}. Additional tokens are paired against the hub by {addSpoke}.
 *         Per-token state is keyed by V4 `PoolId`.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Unispring is IUnlockCallback {
    using StateLibrary for IPoolManager;

    /**
     * @notice The Uniswap V4 PoolManager, resolved from the `IAddressLookup`
     *         supplied at construction.
     */
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice Pool fee, in hundredths of a bip. Uniswap's LOWEST canonical tier
     *         (0.01%) so that `smart-order-router`'s fallback enumeration
     *         discovers every pool. Fees accrue to the single-sided position and
     *         are periodically plowed back into liquidity via {plow}.
     */
    uint24 public constant FEE = 100;

    /**
     * @notice Tick spacing — canonical pairing for the LOWEST fee tier and
     *         maximum granularity at the floor.
     */
    int24 public constant TICK_SPACING = 1;

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
     * @notice Price floor the hub pool is seeded at, in hub-priced-in-ETH
     *         semantics. Frozen at construction; consumed by {seedHub}.
     */
    int24 public immutable HUB_TICK_FLOOR;

    /**
     * @notice The pool id of the native ETH / hub pool, set once by {seedHub}.
     * @dev Non-zero iff the hub pool has been initialized and seeded.
     */
    PoolId public hubPool;

    /**
     * @notice The new token created by Unispring for a given pool.
     */
    mapping(PoolId => IERC20) public poolToken;

    /**
     * @notice Price floor of the position for a given token, in
     *         spoke-token-priced-in-counterparty semantics.
     * @dev    Set once in {addSpoke} (or {seedHub} for the hub token). Used by
     *         {plow} to reconstruct the full position coordinates from just
     *         a token address.
     */
    mapping(address => int24) public floor;

    /**
     * @notice Emitted when a pool is initialized, paired against the hub, and seeded.
     * @param seeder    The address that called {addSpoke} or {seedHub}.
     * @param token     The spoke token (or the hub, for {seedHub}).
     * @param poolId    The Uniswap V4 pool id.
     * @param supply    The fixed supply seeded into the pool.
     * @param tickFloor The price floor in spoke-token-priced-in-counterparty
     *                  semantics.
     */
    event Seeded(address indexed seeder, IERC20 indexed token, PoolId indexed poolId, uint256 supply, int24 tickFloor);

    /**
     * @notice Emitted when {plow} compounds fees back into a position.
     * @param caller       Permissionless caller who triggered the compounding.
     * @param poolId       The pool whose position was plowed.
     * @param liquidityAdded Additional liquidity deposited into the existing position.
     */
    event Plowed(address indexed caller, PoolId indexed poolId, uint128 liquidityAdded);

    /**
     * @notice Thrown when `tickFloor` is not a multiple of {TICK_SPACING}.
     */
    error TickFloorMisaligned(int24 tickFloor);

    /**
     * @notice Thrown when `tickFloor` is not strictly inside `(MIN_TICK, MAX_TICK)`.
     */
    error TickFloorOutOfRange(int24 tickFloor);

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
     * @notice Thrown when a pool with the same key has already been created.
     */
    error PoolAlreadyExists(PoolId id);

    /**
     * @notice Thrown when {seedHub} is called after the hub pool has already been seeded.
     */
    error HubAlreadySeeded();

    /**
     * @notice Thrown when {plow} is called with a token address that was not
     *         created by this factory.
     */
    error UnknownToken(address token);

    /**
     * @notice Thrown when {unlockCallback} is invoked by anyone other than the PoolManager.
     */
    error InvalidUnlockCaller();

    /**
     * @notice Thrown if liquidity computed from supply exceeds `uint128`.
     */
    error LiquidityOverflow();

    /**
     * @dev Discriminator for the unlock callback payload.
     */
    enum Action {
        SEED_CURRENCY0,
        SEED_CURRENCY1,
        PLOW,
        BUY_HUB
    }

    /**
     * @dev Internal payload used to seed a single-sided currency0 position
     *      (every {make}-created pool).
     */
    struct SeedCurrency0Data {
        PoolKey key;
        uint256 supply;
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @dev Internal payload used to seed a single-sided currency1 position
     *      (the constructor-created hub pool).
     */
    struct SeedCurrency1Data {
        PoolKey key;
        uint256 supply;
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @dev Internal payload used to compound fees into an existing position.
     */
    struct PlowData {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
    }

    /**
     * @dev Internal payload for the hub bootstrap swap.
     */
    struct BuyHubData {
        address recipient;
        uint256 amountIn;
    }

    /**
     * @notice Construct the Unispring seeder bound to an externally-supplied hub.
     * @dev    The hub pool is NOT seeded here. A contract cannot receive callbacks
     *         during its own construction (its runtime code isn't deployed yet),
     *         so pool seeding is deferred to {seedHub}, which must be called once
     *         after the hub's full intended pool supply has been transferred to
     *         this contract.
     * @param  poolManagerLookup `IAddressLookup` resolving the chain-local
     *                       Uniswap V4 PoolManager. Dereferenced once in the
     *                       constructor and stored as {POOL_MANAGER}.
     * @param  hub           The hub token. Stored as {HUB}.
     * @param  hubTickFloor  Price floor for the hub, expressed in hub-priced-in-ETH
     *                       semantics. Must be a multiple of {TICK_SPACING} and
     *                       strictly inside `(MIN_TICK, MAX_TICK)`.
     */
    constructor(IAddressLookup poolManagerLookup, IERC20 hub, int24 hubTickFloor) {
        if (hubTickFloor % TICK_SPACING != 0) revert TickFloorMisaligned(hubTickFloor);
        if (hubTickFloor <= TickMath.MIN_TICK || hubTickFloor >= TickMath.MAX_TICK) {
            revert TickFloorOutOfRange(hubTickFloor);
        }

        POOL_MANAGER = IPoolManager(poolManagerLookup.value());
        HUB = address(hub);
        HUB_TICK_FLOOR = hubTickFloor;
    }

    /**
     * @notice Allow Unispring to receive native ETH from the PoolManager's `take`
     *         during {plow}.
     */
    receive() external payable {}

    /**
     * @notice Initialize the hub's ETH pool and seed it single-sided with the
     *         hub balance currently held by this contract. Callable exactly once.
     * @dev    Permissionless — any caller may trigger it. The deploy script
     *         transfers the full hub supply to this contract and then calls
     *         this immediately. Subsequent calls revert. The seed is the
     *         fencepost "mirror" case (single-sided currency1 at the upper
     *         boundary, inactive at spot until the first ETH→HUB swap crosses
     *         the boundary downward). A bootstrap swap is expected right after
     *         this call so the pool shows as active to quoters and hosted
     *         front-ends.
     * @return poolId The pool id of the newly seeded hub pool.
     */
    function seedHub() external returns (PoolId poolId) {
        if (PoolId.unwrap(hubPool) != bytes32(0)) revert HubAlreadySeeded();

        uint256 supply = IERC20(HUB).balanceOf(address(this));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(HUB),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = -HUB_TICK_FLOOR;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        poolId = key.toId();
        hubPool = poolId;
        poolToken[poolId] = IERC20(HUB);
        floor[HUB] = HUB_TICK_FLOOR;

        IPoolManager pm = POOL_MANAGER;
        pm.initialize(key, sqrtPriceX96);
        pm.unlock(
            abi.encode(
                Action.SEED_CURRENCY1,
                abi.encode(SeedCurrency1Data({key: key, supply: supply, tickLower: tickLower, tickUpper: tickUpper}))
            )
        );

        emit Seeded(msg.sender, IERC20(HUB), poolId, supply, HUB_TICK_FLOOR);
    }

    /**
     * @notice Pair an already-deployed token against the hub and lock `supply`
     *         into a single-sided V4 position with a permanent floor.
     * @dev    The spoke token must sort strictly below {HUB} so that it becomes
     *         `currency0` of the pool. Caller must approve this contract to pull
     *         `supply` tokens; the pulled balance is then locked into the seed
     *         position.
     * @param  token     The spoke token to pair against the hub.
     * @param  supply    Amount of `token` to pull from the caller and seed into
     *                   the position.
     * @param  tickFloor Price floor expressed in spoke-in-hub semantics. Must be
     *                   a multiple of {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     * @return poolId    The Uniswap V4 pool id.
     */
    function addSpoke(IERC20 token, uint256 supply, int24 tickFloor) external returns (PoolId poolId) {
        if (tickFloor % TICK_SPACING != 0) revert TickFloorMisaligned(tickFloor);
        if (tickFloor <= TickMath.MIN_TICK || tickFloor >= TickMath.MAX_TICK) {
            revert TickFloorOutOfRange(tickFloor);
        }

        // 1. Enforce currency0 ordering: spoke must sort strictly below the hub.
        if (address(token) >= HUB) revert SpokeMustSortBelowHub(address(token));

        // 2. Pull the seed supply from the caller.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(msg.sender, address(this), supply);

        // 3. Build the pool key. Spoke is currency0; floor on token-in-hub price
        //    equals floor on pool tick. Range [tickFloor, MAX]; pool price seeded at
        //    the lower bound; the position is single-sided in currency0 and active.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(token)),
            currency1: Currency.wrap(HUB),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        int24 tickLower = tickFloor;
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tickLower);

        poolId = key.toId();
        if (address(poolToken[poolId]) != address(0)) revert PoolAlreadyExists(poolId);
        poolToken[poolId] = token;
        floor[address(token)] = tickLower;

        // 4. Initialize the pool and seed the position via the unlock callback.
        IPoolManager pm = POOL_MANAGER;
        pm.initialize(key, sqrtPriceX96);
        pm.unlock(
            abi.encode(
                Action.SEED_CURRENCY0,
                abi.encode(SeedCurrency0Data({key: key, supply: supply, tickLower: tickLower, tickUpper: tickUpper}))
            )
        );

        emit Seeded(msg.sender, token, poolId, supply, tickFloor);
    }

    /**
     * @notice Permissionlessly compound accrued fees back into a Unispring
     *         position. Anyone can call. No operator role, no reward.
     * @dev    Reconstructs the full pool key and tick range from the token
     *         address alone, then collects fees and deposits as much of the
     *         collected amounts as possible back into the same position as
     *         additional liquidity. Any leftover of one side stays in the
     *         factory's balance and is consumed on a future call once the
     *         other side has caught up.
     * @param  token  Address of a token created by this factory (or {HUB}
     *                   for the hub pool).
     */
    function plow(address token) external {
        int24 f = floor[token];
        if (f == 0) revert UnknownToken(token);

        PoolKey memory key;
        int24 tickLower;
        int24 tickUpper;

        if (token == HUB) {
            // Hub pool: ETH is currency0, HUB is currency1.
            key = PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(HUB),
                fee: FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
            tickLower = TickMath.minUsableTick(TICK_SPACING);
            tickUpper = -f;
        } else {
            // Regular pool: token is currency0, HUB is currency1.
            key = PoolKey({
                currency0: Currency.wrap(token),
                currency1: Currency.wrap(HUB),
                fee: FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(address(0))
            });
            tickLower = f;
            tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        }

        POOL_MANAGER.unlock(
            abi.encode(Action.PLOW, abi.encode(PlowData({key: key, tickLower: tickLower, tickUpper: tickUpper})))
        );
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
        if (action == Action.SEED_CURRENCY0) {
            _seedCurrency0(pm, abi.decode(inner, (SeedCurrency0Data)));
        } else if (action == Action.SEED_CURRENCY1) {
            _seedCurrency1(pm, abi.decode(inner, (SeedCurrency1Data)));
        } else if (action == Action.PLOW) {
            _plow(pm, abi.decode(inner, (PlowData)));
        } else {
            _buyHub(pm, abi.decode(inner, (BuyHubData)));
        }
        return "";
    }

    /**
     * @dev Seed a single-sided currency0 position with `supply` tokens.
     */
    function _seedCurrency0(IPoolManager pm, SeedCurrency0Data memory cb) private {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cb.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cb.tickUpper);
        uint128 liquidity = _liquidityForAmount0(sqrtLower, sqrtUpper, cb.supply);

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

        // The position is single-sided in currency0, so only `amount0` is owed.
        // `amount0` is non-positive (a debit owed by the caller); negation fits in uint128.
        int128 amount0 = delta.amount0();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount0));

        IERC20 newToken = IERC20(Currency.unwrap(cb.key.currency0));
        pm.sync(cb.key.currency0);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        newToken.transfer(address(pm), owed);
        pm.settle();
    }

    /**
     * @dev Seed a single-sided currency1 position with `supply` tokens. Only used
     *      by the constructor to seed the hub's ETH pool.
     */
    function _seedCurrency1(IPoolManager pm, SeedCurrency1Data memory cb) private {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cb.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cb.tickUpper);
        uint128 liquidity = _liquidityForAmount1(sqrtLower, sqrtUpper, cb.supply);

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

        // The position is single-sided in currency1, so only `amount1` is owed.
        int128 amount1 = delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount1));

        IERC20 hubToken = IERC20(Currency.unwrap(cb.key.currency1));
        pm.sync(cb.key.currency1);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        hubToken.transfer(address(pm), owed);
        pm.settle();
    }

    /**
     * @dev Compound accrued fees into an existing position. Collects fees via a
     *      zero-delta `modifyLiquidity`, withdraws them to this contract, then
     *      adds as much liquidity as the collected amounts (plus any carryover)
     *      support at the current tick.
     */
    function _plow(IPoolManager pm, PlowData memory cb) private {
        PoolId poolId = cb.key.toId();

        // 1. Collect fees. With liquidityDelta == 0, the returned `callerDelta`
        //    is exactly the accrued fees, owed TO us (non-negative on both sides).
        (BalanceDelta collectDelta,) = pm.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower, tickUpper: cb.tickUpper, liquidityDelta: int256(0), salt: bytes32(0)
            }),
            ""
        );

        int128 collected0 = collectDelta.amount0();
        int128 collected1 = collectDelta.amount1();
        // Non-negative by construction, but guard against any surprise.
        if (collected0 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            pm.take(cb.key.currency0, address(this), uint256(uint128(collected0)));
        }
        if (collected1 > 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            pm.take(cb.key.currency1, address(this), uint256(uint128(collected1)));
        }

        // 2. Read current pool price to size the new liquidity deposit.
        (uint160 sqrtCurrent,,,) = pm.getSlot0(poolId);
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cb.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cb.tickUpper);

        // 3. Max liquidity we can add given our current balances of both
        //    currencies at this pool's current price.
        uint256 balance0 = _balanceOf(cb.key.currency0);
        uint256 balance1 = _balanceOf(cb.key.currency1);
        uint128 liquidityToAdd = _liquidityForAmounts(sqrtCurrent, sqrtLower, sqrtUpper, balance0, balance1);
        if (liquidityToAdd == 0) {
            emit Plowed(tx.origin, poolId, 0);
            return;
        }

        // 4. Add the liquidity. Protocol will tell us exactly how much of each
        //    token it needs.
        (BalanceDelta addDelta,) = pm.modifyLiquidity(
            cb.key,
            ModifyLiquidityParams({
                tickLower: cb.tickLower,
                tickUpper: cb.tickUpper,
                liquidityDelta: int256(uint256(liquidityToAdd)),
                salt: bytes32(0)
            }),
            ""
        );

        _settleOwed(pm, cb.key.currency0, addDelta.amount0());
        _settleOwed(pm, cb.key.currency1, addDelta.amount1());

        emit Plowed(tx.origin, poolId, liquidityToAdd);
    }

    /**
     * @dev Execute an exact-input ETH → HUB swap and forward received HUB to the
     *      recipient. Called inside `unlockCallback`.
     */
    function _buyHub(IPoolManager pm, BuyHubData memory cb) private {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(HUB),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

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
     * @dev Settle a non-positive delta owed to the PoolManager, paying in either
     *      native ETH or ERC-20 depending on the currency.
     */
    function _settleOwed(IPoolManager pm, Currency currency, int128 amount) private {
        if (amount >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount));
        if (currency.isAddressZero()) {
            pm.settle{value: owed}();
        } else {
            pm.sync(currency);
            IERC20 erc = IERC20(Currency.unwrap(currency));
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            erc.transfer(address(pm), owed);
            pm.settle();
        }
    }

    /**
     * @dev Balance of `currency` held by this contract, for both ETH and ERC-20.
     */
    function _balanceOf(Currency currency) private view returns (uint256) {
        if (currency.isAddressZero()) return address(this).balance;
        return IERC20(Currency.unwrap(currency)).balanceOf(address(this));
    }

    /**
     * @dev Liquidity for a single-sided position in currency0.
     *      L = amount0 * (sqrtLower * sqrtUpper / Q96) / (sqrtUpper - sqrtLower)
     */
    function _liquidityForAmount0(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount0)
        private
        pure
        returns (uint128)
    {
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtLower), uint256(sqrtUpper), FixedPoint96.Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, uint256(sqrtUpper - sqrtLower)));
    }

    /**
     * @dev Liquidity for a single-sided position in currency1.
     *      L = amount1 * Q96 / (sqrtUpper - sqrtLower)
     */
    function _liquidityForAmount1(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1)
        private
        pure
        returns (uint128)
    {
        return _toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, uint256(sqrtUpper - sqrtLower)));
    }

    /**
     * @dev Maximum liquidity addable to `[lower, upper]` at the current sqrt price,
     *      given available balances of `amount0` and `amount1`.
     */
    function _liquidityForAmounts(
        uint160 sqrtCurrent,
        uint160 sqrtLower,
        uint160 sqrtUpper,
        uint256 amount0,
        uint256 amount1
    ) private pure returns (uint128) {
        if (sqrtCurrent <= sqrtLower) {
            return _liquidityForAmount0(sqrtLower, sqrtUpper, amount0);
        }
        if (sqrtCurrent >= sqrtUpper) {
            return _liquidityForAmount1(sqrtLower, sqrtUpper, amount1);
        }
        uint128 l0 = _liquidityForAmount0(sqrtCurrent, sqrtUpper, amount0);
        uint128 l1 = _liquidityForAmount1(sqrtLower, sqrtCurrent, amount1);
        return l0 < l1 ? l0 : l1;
    }

    function _toUint128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert LiquidityOverflow();
        // safe: bounds checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }
}
