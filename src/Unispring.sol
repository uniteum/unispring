// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
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
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/**
 * @title Unispring
 * @notice Fair-launch pool funder on Uniswap V4 — permanent liquidity, built-in
 *         price floor, hub-paired spokes. Zero-fee pools.
 * @dev    See README.md for the full design rationale. The hub token is supplied
 *         externally at construction; its ETH pool is funded single-sided by
 *         {zzInit}. Additional tokens are paired against the hub by {fund}.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Unispring is IUnlockCallback {
    string public constant VERSION = "0.1.0";

    using StateLibrary for IPoolManager;

    /**
     * @dev Internal payload used to fund a single-sided position. `currency0Sided`
     *      selects which side of the pair the supply funds: `true` for every
     *      {fund}-created pool, `false` for the {zzInit}-created hub pool.
     */
    struct FundData {
        PoolKey key;
        uint256 supply;
        int24 tickLower;
        int24 tickUpper;
        bool currency0Sided;
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
     * @notice The prototype instance that acts as the Bitsy factory.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Unispring public immutable PROTO;

    /**
     * @notice The Uniswap V4 PoolManager, resolved from the `IAddressLookup`
     *         supplied at construction.
     */
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice The hub token, set during {zzInit} for each clone.
     * @dev    The full hub supply must be transferred to the clone's deterministic
     *         address (obtainable via {made}) before {make} is called. {zzInit}
     *         reads `hub.balanceOf(this)` as the amount to fund. Deploy scripts
     *         salt-mine the hub's address so it has many leading `f` bytes, which
     *         makes future {fund} calls succeed with spoke tokens whose
     *         addresses sort strictly below the hub.
     */
    address public hub;

    /**
     * @notice Emitted when a new clone is created via {make}.
     */
    event Make(Unispring indexed clone, IERC20 indexed hub, int24 tickLower, int24 tickUpper);

    /**
     * @notice Emitted when a pool is initialized, paired against the hub, and funded.
     * @param funder    The address that called {fund} (or PROTO for {zzInit}).
     * @param token     The spoke token (or the hub, for {zzInit}).
     * @param poolId    The Uniswap V4 pool id.
     * @param supply    The fixed supply funded into the pool.
     * @param tickLower Lower tick of the funded position.
     * @param tickUpper Upper tick of the funded position.
     */
    event Funded(
        address indexed funder,
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
     * @notice Thrown when the spoke token does not sort strictly below {hub}.
     * @dev    {fund} requires `token < hub` so the spoke becomes `currency0`
     *         of the pool. This is the only currency ordering under which a
     *         single-sided funded position is both active at spot and requires
     *         zero hub capital; see README.md for the full derivation. Mine a
     *         different spoke salt until the deterministic address sorts below
     *         {hub}.
     */
    error SpokeMustSortBelowHub(address token);

    /**
     * @notice Thrown when {unlockCallback} is invoked by anyone other than the PoolManager.
     */
    error InvalidUnlockCaller();

    /**
     * @notice Thrown when {zzInit} is called by anyone other than {PROTO}.
     */
    error Unauthorized();

    /**
     * @notice Thrown if liquidity computed from supply exceeds `uint128`.
     */
    error LiquidityOverflow();

    /**
     * @notice Construct the prototype. Clones are created via {make}.
     * @param  poolManagerLookup `IAddressLookup` resolving the chain-local
     *                           Uniswap V4 PoolManager.
     */
    constructor(IAddressLookup poolManagerLookup) {
        PROTO = this;
        POOL_MANAGER = IPoolManager(poolManagerLookup.value());
    }

    // ---- Bitsy factory ----

    /**
     * @notice Predict the deterministic address of a clone.
     * @return exists True if the clone is already deployed.
     * @return home   The deterministic clone address.
     * @return salt   The CREATE2 salt.
     */
    function made(IERC20 hub_, int24 tickLower, int24 tickUpper)
        public
        view
        returns (bool exists, address home, bytes32 salt)
    {
        salt = keccak256(abi.encode(hub_, tickLower, tickUpper));
        home = Clones.predictDeterministicAddress(address(PROTO), salt, address(PROTO));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy a deterministic clone for the given hub and tick range.
     *         Idempotent — returns the existing clone if already deployed.
     * @return clone The deployed (or existing) clone.
     */
    function make(IERC20 hub_, int24 tickLower, int24 tickUpper) external returns (Unispring clone) {
        if (address(this) != address(PROTO)) {
            clone = PROTO.make(hub_, tickLower, tickUpper);
        } else {
            (bool exists, address home, bytes32 salt) = made(hub_, tickLower, tickUpper);
            clone = Unispring(payable(home));
            if (!exists) {
                Clones.cloneDeterministic(address(PROTO), salt, 0);
                Unispring(payable(home)).zzInit(hub_, tickLower, tickUpper);
                emit Make(clone, hub_, tickLower, tickUpper);
            }
        }
    }

    /**
     * @notice Initializer called by PROTO on a freshly deployed clone. Sets the
     *         hub token, initializes the hub's ETH pool, and funds it single-sided
     *         with the hub balance already held by this clone.
     * @dev    The clone's deterministic address (from {made}) must hold the hub
     *         supply before {make} is called. The position is single-sided currency1
     *         at the upper boundary, inactive at spot until the first ETH→HUB swap
     *         crosses the boundary downward.
     */
    function zzInit(IERC20 hub_, int24 tickLower, int24 tickUpper) external {
        if (msg.sender != address(PROTO)) revert Unauthorized();
        hub = address(hub_);
        uint256 supply = hub_.balanceOf(address(this));
        hub_.approve(address(this), supply);
        this.fund(hub_, supply, tickLower, tickUpper);
    }

    /**
     * @notice Lock `supply` tokens into a single-sided V4 position with a
     *         permanent floor, paired against the hub.
     * @dev    The spoke token must sort strictly below {hub} so that it becomes
     *         `currency0` of the pool. Caller must approve this contract to pull
     *         `supply` tokens; the pulled balance is then locked into the funded
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
     *              single-locker model. A hook cannot re-enter {fund} /
     *              {zzInit} (each calls `POOL_MANAGER.unlock`, which reverts
     *              on nested entry), and it cannot call the PoolManager
     *              directly because `modifyLiquidity` requires the caller to
     *              be the active locker.
     *           3. Fee-on-transfer or revert-on-transfer causes {_fund}'s
     *              `settle` step to underpay or revert, unwinding the whole
     *              fund atomically. No partial state.
     * @param  token     The token to pair against the hub.
     * @param  supply    Amount of `token` to pull from the caller and fund into
     *                   the position.
     * @param  tickLower Lower tick (price floor in spoke-in-hub semantics).
     *                   Must be a multiple of {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     * @param  tickUpper Upper tick of the position. Must be a multiple of
     *                   {TICK_SPACING} and strictly inside
     *                   `(MIN_TICK, MAX_TICK)`.
     */
    function fund(IERC20 token, uint256 supply, int24 tickLower, int24 tickUpper) external {
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transferFrom(msg.sender, address(this), supply);
        _requireValidTickRange(tickLower, tickUpper);

        address tokenAddr = address(token);
        bool currency0Sided = tokenAddr != hub;
        if (currency0Sided && tokenAddr >= hub) revert SpokeMustSortBelowHub(tokenAddr);

        PoolKey memory key = _poolKey(currency0Sided ? tokenAddr : address(0));
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(currency0Sided ? tickLower : tickUpper));
        }
        POOL_MANAGER.unlock(
            abi.encode(
                FundData({
                    key: key, supply: supply, tickLower: tickLower, tickUpper: tickUpper, currency0Sided: currency0Sided
                })
            )
        );

        emit Funded(msg.sender, token, poolId, supply, tickLower, tickUpper);
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidUnlockCaller();
        _fund(abi.decode(data, (FundData)));
        return "";
    }

    /**
     * @dev Fund a single-sided position with `supply` tokens. `currency0Sided`
     *      selects which side of the pair the supply funds.
     */
    function _fund(FundData memory cb) private {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(cb.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(cb.tickUpper);
        uint128 liquidity = cb.currency0Sided
            ? _liquidity0(sqrtLower, sqrtUpper, cb.supply)
            : _liquidity1(sqrtLower, sqrtUpper, cb.supply);

        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
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

        POOL_MANAGER.sync(currency);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), owed);
        POOL_MANAGER.settle();
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
     * @dev Build a pool key with the given currency0 paired against {hub}.
     *      Pass `address(0)` for the hub pool (ETH/hub), or a spoke token
     *      address for a spoke pool. Caller must ensure `currency0 < hub`.
     */
    function _poolKey(address currency0) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(hub),
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
