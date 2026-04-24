// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {Ownable} from "ownable/Ownable.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @dev Record of a single Fountain-owned liquidity position. Stored in the
 *      {Fountain.positions} registry so {Fountain.take} can reconstruct
 *      the position without re-deriving it from call inputs.
 */
struct Position {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
}

/**
 * @dev Selector-dispatch interface for payloads passed through
 *      {Fountain.unlockCallback}. Fountain never implements or exposes
 *      these functions; the signatures exist only so `abi.encodeCall` can
 *      type-check arguments and derive selectors at compile time.
 */
interface IFountainActions {
    function offer(PoolKey calldata key, int24[] calldata userTicks, uint256[] calldata amounts, bool tokenIsCurrency0)
        external;

    function take(uint256[] calldata ids) external;
}

/**
 * @title Fountain
 * @notice Shapes a bonding curve for an externally-supplied token (ERC-20
 *         or native ETH) by seating multiple permanent, single-sided V4
 *         positions against a quote currency (ERC-20 or native ETH).
 *         Callers partition a price range with an ascending array of
 *         V4-native ticks (matching
 *         Unispring and Mimicoinage) and assign a token amount to each
 *         segment; Fountain flips and negates into V4-native tick ranges
 *         when the token sorts above the quote (forcing it into
 *         `currency1`), then seats every segment in a single unlock.
 * @dev    Bitsy factory: the prototype is permissionless and governance-free;
 *         clones are deployed per-caller via {make} and carry their own
 *         {owner} in storage. Each clone's owner is the `msg.sender` that
 *         called {make}; one clone exists per owner address.
 * @dev    Positions are permanent — no function on this contract decreases
 *         or unwinds liquidity. {take} forwards accrued swap fees to the
 *         clone's {owner}.
 * @dev    Fixed pool parameters: {FEE} = 100 (0.01%),
 *         {TICK_SPACING} = 1, no hooks. Spacing 1 gives exact tick
 *         precision for position bounds and the initial price; the
 *         extra bitmap-iteration cost on large swaps is negligible
 *         for Fountain's single-position usage pattern.
 * @dev    Tick convention: callers pass ticks in V4-native semantics
 *         (`log_1.0001(currency1/currency0)` = `log_1.0001(quote/token)`
 *         when the token is `currency0`). When the token sorts below the
 *         quote it becomes `currency0` and the mapping is the identity:
 *         user segment `[T[i], T[i+1])` is seated at V4 `[T[i], T[i+1])`.
 *         When the token sorts above the quote it becomes `currency1`,
 *         V4's internal price becomes the reciprocal, and Fountain maps
 *         `[T[i], T[i+1])` to V4 `[-T[i+1], -T[i])` so the user's intent
 *         is preserved.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Fountain is IUnlockCallback, Ownable {
    string public constant VERSION = "0.4.0";

    /**
     * @notice Pool fee in hundredths of a bip (0.01%).
     */
    uint24 public constant FEE = 100;

    /**
     * @notice Pool tick spacing. Fixed at 1 for exact tick precision.
     */
    int24 public constant TICK_SPACING = 1;

    /**
     * @notice The prototype instance. On clones, this points back to the
     *         original deployment.
     */
    Fountain public immutable PROTO = this;

    /**
     * @notice The Uniswap V4 PoolManager, resolved from the `IAddressLookup`
     *         supplied at construction. Shared by the prototype and every
     *         clone (baked into the prototype's runtime bytecode).
     */
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice All positions seated by this contract, in creation order.
     *         Auto-generated getter returns a single element by index; use
     *         {positionsCount} and {positionsSlice} for bulk reads.
     */
    Position[] public positions;

    /**
     * @notice Emitted when an {offer} call seats a contiguous batch of
     *         positions.
     * @param  offerer          The address that called {offer}.
     * @param  token            The currency whose supply seats the positions
     *                          (`Currency.wrap(address(0))` for native ETH).
     * @param  quote            The quote currency (`Currency.wrap(address(0))`
     *                          for native ETH).
     * @param  poolId           The Uniswap V4 pool id.
     * @param  firstPositionId  Index of the first position in the batch.
     * @param  positionCount    Number of positions in the batch.
     */
    event Offered(
        address indexed offerer,
        Currency indexed token,
        Currency quote,
        PoolId indexed poolId,
        uint256 firstPositionId,
        uint256 positionCount
    );

    /**
     * @notice Emitted when {take} forwards fees for one position to {owner}.
     */
    event Taken(uint256 indexed positionId, PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /**
     * @notice Emitted when {make} deploys a new clone.
     */
    event Made(address indexed owner, uint256 indexed variant, Fountain indexed home);

    /**
     * @notice Thrown when {unlockCallback} is invoked by anyone other than the PoolManager.
     */
    error InvalidUnlockCaller();

    /**
     * @notice Thrown when {unlockCallback} receives a selector it does not handle.
     */
    error UnknownSelector(bytes4 selector);

    /**
     * @notice Thrown when `amounts.length + 1 != ticks.length`.
     */
    error TickAmountLengthMismatch(uint256 ticksLength, uint256 amountsLength);

    /**
     * @notice Thrown when {offer} is called with an empty `amounts` array.
     */
    error NoPositions();

    /**
     * @notice Thrown when a tick falls outside `[MIN_TICK, MAX_TICK]`.
     */
    error TickOutOfRange(int24 tick);

    /**
     * @notice Thrown when ticks are not strictly ascending.
     */
    error TicksNotAscending(uint256 index, int24 prev, int24 curr);

    /**
     * @notice Thrown when a per-segment amount is zero.
     */
    error ZeroAmount(uint256 index);

    /**
     * @notice Thrown if liquidity computed from a segment's amount exceeds `uint128`.
     */
    error LiquidityOverflow();

    /**
     * @notice Thrown when the pool exists at a price other than the starting
     *         price this {offer} call would have initialized it to. Pools are
     *         permanent once initialized in V4, so recovery is not possible
     *         on the affected {PoolKey}; choose a different quote to produce
     *         a different pool.
     */
    error PoolPreInitialized(uint160 sqrtPriceX96);

    /**
     * @notice Thrown when {take} references a position index that does not exist.
     */
    error UnknownPosition(uint256 positionId);

    /**
     * @notice Thrown when `msg.value` does not match the native value
     *         required by {offer}: `total` when `token` is native ETH,
     *         zero when `token` is an ERC-20.
     */
    error NativeValueMismatch(uint256 expected, uint256 actual);

    /**
     * @notice Thrown when {zzInit} is called by anyone other than the prototype,
     *         or when {make} is called on a clone instead of the prototype.
     */
    error Unauthorized();

    /**
     * @notice Construct the Fountain prototype. The deployer becomes the
     *         prototype's owner; clones receive their own owner via
     *         {zzInit} at {make} time.
     * @param  poolManagerLookup Lookup for the chain-local Uniswap V4 PoolManager.
     */
    constructor(IAddressLookup poolManagerLookup) Ownable(msg.sender) {
        POOL_MANAGER = IPoolManager(poolManagerLookup.value());
    }

    using StateLibrary for IPoolManager;

    /**
     * @notice Offer `token` for sale at the ticks you set, paired against
     *         `quote`. The `ticks` array partitions a "token/quote" price
     *         range into N = `amounts.length` segments; `amounts[i]` seats
     *         the segment bounded by `ticks[i]` and `ticks[i + 1]`
     *         single-sided in `token`. Trading fees accrue to this clone's
     *         {owner}. When `token` is an ERC-20 the caller must have
     *         approved this contract for the sum of `amounts`; when `token`
     *         is native ETH (`Currency.wrap(address(0))`) the caller must
     *         send that sum as `msg.value`.
     * @dev    The lowest tick `ticks[0]` is treated as the pool's starting
     *         price: if the pool does not yet exist it is initialized at
     *         that price; if it already exists its price must match
     *         exactly, else {PoolPreInitialized} reverts.
     * @param  token           The currency whose supply seats the positions
     *                         (`Currency.wrap(address(0))` for native ETH).
     * @param  quote           The quote currency (`Currency.wrap(address(0))`
     *                         for native ETH).
     * @param  ticks           Strictly ascending ticks in "token/quote"
     *                         price semantics. Length N + 1 for N positions.
     * @param  amounts         Per-segment token amounts. Length N, all
     *                         non-zero.
     * @return firstPositionId Index of the first position created by this
     *                         call; positions in this batch are at ids
     *                         `firstPositionId .. firstPositionId + N - 1`.
     */
    function offer(Currency token, Currency quote, int24[] calldata ticks, uint256[] calldata amounts)
        external
        payable
        returns (uint256 firstPositionId)
    {
        uint256 n = amounts.length;
        if (n == 0) revert NoPositions();
        if (ticks.length != n + 1) revert TickAmountLengthMismatch(ticks.length, n);

        for (uint256 i = 0; i < ticks.length; i++) {
            int24 t = ticks[i];
            if (t < TickMath.MIN_TICK || t > TickMath.MAX_TICK) revert TickOutOfRange(t);
            if (i > 0 && t <= ticks[i - 1]) revert TicksNotAscending(i, ticks[i - 1], t);
        }

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] == 0) revert ZeroAmount(i);
            total += amounts[i];
        }

        bool tokenIsCurrency0 = token < quote;

        if (token.isAddressZero()) {
            if (msg.value != total) revert NativeValueMismatch(total, msg.value);
        } else {
            if (msg.value != 0) revert NativeValueMismatch(0, msg.value);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(token)).transferFrom(msg.sender, address(this), total);
        }

        PoolKey memory key = PoolKey({
            currency0: tokenIsCurrency0 ? token : quote,
            currency1: tokenIsCurrency0 ? quote : token,
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        PoolId poolId = key.toId();

        int24 startingV4Tick = tokenIsCurrency0 ? ticks[0] : -ticks[0];
        uint160 startingSqrtPriceX96 = TickMath.getSqrtPriceAtTick(startingV4Tick);

        (uint160 existingSqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (existingSqrtPriceX96 == 0) {
            POOL_MANAGER.initialize(key, startingSqrtPriceX96);
        } else if (existingSqrtPriceX96 != startingSqrtPriceX96) {
            revert PoolPreInitialized(existingSqrtPriceX96);
        }

        firstPositionId = positions.length;
        POOL_MANAGER.unlock(abi.encodeCall(IFountainActions.offer, (key, ticks, amounts, tokenIsCurrency0)));

        emit Offered(msg.sender, token, quote, poolId, firstPositionId, n);
    }

    /**
     * @notice Take accrued swap fees for a single position and forward
     *         them to {owner}.
     */
    function take(uint256 positionId) external {
        uint256[] memory ids = new uint256[](1);
        ids[0] = positionId;
        _takeMany(ids);
    }

    /**
     * @notice Take accrued swap fees for several positions in a single
     *         unlock and forward them to {owner}. Reverts with
     *         {UnknownPosition} if any id is out of range.
     */
    function take(uint256[] calldata ids) external {
        _takeMany(ids);
    }

    /**
     * @notice The number of positions seated by this contract.
     */
    function positionsCount() external view returns (uint256) {
        return positions.length;
    }

    /**
     * @notice Return a contiguous slice of {positions}. Clamps to the array
     *         bounds: `offset` at or past the end returns an empty array;
     *         `count` running past the end returns only the existing tail.
     */
    function positionsSlice(uint256 offset, uint256 count) external view returns (Position[] memory slice) {
        uint256 length = positions.length;
        if (offset >= length) return new Position[](0);
        uint256 end = offset + count;
        if (end > length) end = length;
        slice = new Position[](end - offset);
        for (uint256 i = 0; i < slice.length; i++) {
            slice[i] = positions[offset + i];
        }
    }

    /**
     * @notice Return untaken swap fees owed to each referenced position.
     *         Values match what {take} would transfer to {owner} if
     *         called now. Amounts are ordered by each position's pool
     *         currencies: `amounts0[i]` is for position `ids[i]`'s
     *         `currency0`.
     * @param  ids Position ids to query. Reverts on any out-of-range id.
     */
    function untaken(uint256[] calldata ids)
        external
        view
        returns (uint256[] memory amounts0, uint256[] memory amounts1)
    {
        amounts0 = new uint256[](ids.length);
        amounts1 = new uint256[](ids.length);
        uint256 length = positions.length;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] >= length) revert UnknownPosition(ids[i]);
            Position storage p = positions[ids[i]];
            (amounts0[i], amounts1[i]) = _untaken(p.key, p.tickLower, p.tickUpper);
        }
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Selector-dispatches on {IFountainActions}: either seats a batch
     *      of positions or iterates a batch of ids for fee take.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidUnlockCaller();
        bytes4 selector = bytes4(data[:4]);
        if (selector == IFountainActions.offer.selector) {
            (PoolKey memory key, int24[] memory userTicks, uint256[] memory amounts, bool tokenIsCurrency0) =
                abi.decode(data[4:], (PoolKey, int24[], uint256[], bool));
            _offerAll(key, userTicks, amounts, tokenIsCurrency0);
        } else if (selector == IFountainActions.take.selector) {
            uint256[] memory ids = abi.decode(data[4:], (uint256[]));
            for (uint256 i = 0; i < ids.length; i++) {
                Position storage p = positions[ids[i]];
                _take(ids[i], p.key, p.tickLower, p.tickUpper);
            }
        } else {
            revert UnknownSelector(selector);
        }
        return "";
    }

    /**
     * @dev Validate ids against the registry and dispatch a single unlock
     *      that takes all of them.
     */
    function _takeMany(uint256[] memory ids) private {
        if (ids.length == 0) return;
        uint256 length = positions.length;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] >= length) revert UnknownPosition(ids[i]);
        }
        POOL_MANAGER.unlock(abi.encodeCall(IFountainActions.take, (ids)));
    }

    /**
     * @dev Seat every segment of the caller-described curve in one unlock.
     *      User segment [userTicks[i], userTicks[i+1]) with amount[i]
     *      seats a V4 position at [userTicks[i], userTicks[i+1]) when the
     *      token is currency0 (identity mapping; matches Unispring and
     *      Mimicoinage), or at [-userTicks[i+1], -userTicks[i]) when the
     *      token is currency1 (flipping under V4's price inversion). Net
     *      token debit is accumulated across positions and settled
     *      against the PoolManager once at the end. The non-token side of
     *      each position has zero delta (single-sided), so no settlement
     *      is needed for the quote currency.
     */
    function _offerAll(PoolKey memory key, int24[] memory userTicks, uint256[] memory amounts, bool tokenIsCurrency0)
        private
    {
        uint256 n = amounts.length;
        int256 totalOwed;
        for (uint256 i = 0; i < n; i++) {
            int24 tickLower;
            int24 tickUpper;
            if (tokenIsCurrency0) {
                tickLower = userTicks[i];
                tickUpper = userTicks[i + 1];
            } else {
                tickLower = -userTicks[i + 1];
                tickUpper = -userTicks[i];
            }

            uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
            uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
            uint128 liquidity = tokenIsCurrency0
                ? _liquidity0(sqrtLower, sqrtUpper, amounts[i])
                : _liquidity1(sqrtLower, sqrtUpper, amounts[i]);

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

            int128 amount = tokenIsCurrency0 ? delta.amount0() : delta.amount1();
            totalOwed += int256(amount);

            positions.push(Position({key: key, tickLower: tickLower, tickUpper: tickUpper}));
        }

        // Total owed is non-positive across single-sided positions; negation is within uint256 range.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(-totalOwed);
        Currency currency = tokenIsCurrency0 ? key.currency0 : key.currency1;
        POOL_MANAGER.sync(currency);
        if (currency.isAddressZero()) {
            POOL_MANAGER.settle{value: owed}();
        } else {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), owed);
            POOL_MANAGER.settle();
        }
    }

    /**
     * @dev Take fees from one Fountain-owned position via a zero-delta
     *      modifyLiquidity and forward them to {owner}.
     */
    function _take(uint256 id, PoolKey memory key, int24 tickLower, int24 tickUpper) private {
        (, BalanceDelta feesAccrued) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)}),
            ""
        );
        int128 fee0 = feesAccrued.amount0();
        int128 fee1 = feesAccrued.amount1();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount0 = fee0 > 0 ? uint256(uint128(fee0)) : 0;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amount1 = fee1 > 0 ? uint256(uint128(fee1)) : 0;
        address recipient = owner();
        if (amount0 > 0) POOL_MANAGER.take(key.currency0, recipient, amount0);
        if (amount1 > 0) POOL_MANAGER.take(key.currency1, recipient, amount1);
        emit Taken(id, key.toId(), amount0, amount1);
    }

    /**
     * @dev Compute untaken fees for a Fountain-owned position. Mirrors
     *      Uniswap's feeGrowthInside delta formula and uses unchecked
     *      subtraction to handle X128 wraparound.
     */
    function _untaken(PoolKey memory key, int24 tickLower, int24 tickUpper)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = key.toId();
        (uint128 liquidity, uint256 growth0Last, uint256 growth1Last) =
            POOL_MANAGER.getPositionInfo(poolId, address(this), tickLower, tickUpper, bytes32(0));
        (uint256 growth0Now, uint256 growth1Now) = POOL_MANAGER.getFeeGrowthInside(poolId, tickLower, tickUpper);
        unchecked {
            amount0 = FullMath.mulDiv(growth0Now - growth0Last, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(growth1Now - growth1Last, liquidity, FixedPoint128.Q128);
        }
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

    /**
     * @notice Predict the deterministic address of the Fountain owned by
     *         `owner_` under `variant`, without deploying.
     * @param  owner_  The address that would own the Fountain.
     * @param  variant Discriminator letting one owner hold multiple Fountains.
     * @return exists  True iff the Fountain has already been deployed.
     * @return home    The predicted (or actual, if `exists`) clone address.
     * @return salt    The CREATE2 salt used for the clone.
     */
    function made(address owner_, uint256 variant) public view returns (bool exists, address home, bytes32 salt) {
        salt = keccak256(abi.encode(owner_, variant));
        home = Clones.predictDeterministicAddress(address(PROTO), salt, address(PROTO));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy (or return) the Fountain owned by `msg.sender` under
     *         `variant`. One Fountain exists per (owner, variant) pair;
     *         repeated calls with the same variant return the same clone.
     * @dev    Must be called on the prototype. Calling on a clone reverts
     *         with {Unauthorized} — `msg.sender` semantics cannot be
     *         preserved across clone forwarding.
     * @param  variant Discriminator letting one owner hold multiple Fountains.
     */
    function make(uint256 variant) external returns (Fountain instance) {
        if (address(this) != address(PROTO)) revert Unauthorized();
        (bool exists, address home, bytes32 salt) = made(msg.sender, variant);
        instance = Fountain(home);
        if (!exists) {
            Clones.cloneDeterministic(address(PROTO), salt, 0);
            instance.zzInit(msg.sender);
            emit Made(msg.sender, variant, instance);
        }
    }

    /**
     * @notice Initializer called by the prototype on a freshly deployed
     *         clone. Sets the clone's owner. Reverts with {Unauthorized}
     *         if called by anyone other than the prototype.
     */
    function zzInit(address owner_) public {
        if (msg.sender != address(PROTO)) revert Unauthorized();
        _transferOwnership(owner_);
    }
}
