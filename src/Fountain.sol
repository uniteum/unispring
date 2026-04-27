// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IPlacer} from "./IPlacer.sol";
import {IPoolConfig} from "./IPoolConfig.sol";
import {IFountainTaker, Position} from "./IFountainTaker.sol";
import {IOwnableMaker} from "./IOwnableMaker.sol";
import {Ownable} from "ownable/Ownable.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

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
 *         V4-native ticks and assign a token amount to each segment;
 *         Fountain flips and negates into V4-native tick ranges when
 *         the token sorts above the quote (forcing it into `currency1`),
 *         then seats every segment in a single unlock.
 * @dev    Bitsy factory: the prototype is permissionless and governance-free;
 *         clones are deployed per-caller via {make} and carry their own
 *         {owner} in storage. Each clone's owner is the `msg.sender` that
 *         called {make}; one clone exists per `(owner, variant)` pair.
 * @dev    Positions are permanent — no function on this contract decreases
 *         or unwinds liquidity. {take} pulls accrued swap fees from the
 *         PoolManager into Fountain's own balance; the {owner} reclaims
 *         them via {withdraw}. Holding fees in Fountain lets {offer} use
 *         a few hundred wei of dust to nudge the starting price one
 *         sqrt-wei interior to the first segment in the flipped (token =
 *         currency1) case, so position 0 has nonzero active liquidity at
 *         genesis instead of sitting at the upper-boundary L=0 dead zone.
 *         When Fountain doesn't have enough of the quote on hand the
 *         start falls back to the boundary.
 * @dev    Fixed pool parameters: {fee} = 100 (0.01%),
 *         {tickSpacing} = 1, no hooks. Spacing 1 gives exact tick
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
contract Fountain is IPlacer, IPoolConfig, IFountainTaker, IOwnableMaker, IUnlockCallback, Ownable {
    string public constant VERSION = "0.6.0";

    /**
     * @inheritdoc IPoolConfig
     */
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint24 public constant fee = 100;

    /**
     * @inheritdoc IPoolConfig
     * @dev Fixed at 1 for exact tick precision.
     */
    // forge-lint: disable-next-line(screaming-snake-case-const)
    int24 public constant tickSpacing = 1;

    /**
     * @notice The prototype instance. On clones, this points back to the
     *         original deployment.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Fountain public immutable proto = this;

    /**
     * @inheritdoc IPoolConfig
     * @dev Resolved from the `IAddressLookup` supplied at construction.
     *      Shared by the prototype and every clone.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    IPoolManager public immutable poolManager;

    /**
     * @notice All positions seated by this contract, in creation order.
     *         Auto-generated getter returns a single element by index; use
     *         {positionsCount} and {positionsSlice} for bulk reads.
     */
    Position[] public positions;

    /**
     * @notice Emitted when {owner} pulls accumulated balance out of Fountain.
     */
    event Withdrawn(address indexed to, Currency indexed currency, uint256 amount);

    /**
     * @notice Thrown when {unlockCallback} is invoked by anyone other than the PoolManager.
     */
    error InvalidUnlockCaller();

    /**
     * @notice Thrown when {unlockCallback} receives a selector it does not handle.
     */
    error UnknownSelector(bytes4 selector);

    /**
     * @notice Thrown when a native-ETH {withdraw} fails because the recipient
     *         rejected the transfer.
     */
    error WithdrawFailed();

    /**
     * @notice Construct the Fountain prototype. The deployer becomes the
     *         prototype's owner; clones receive their own owner via
     *         {zzInit} at {make} time.
     * @param  poolManagerLookup Lookup for the chain-local Uniswap V4 PoolManager.
     */
    constructor(IAddressLookup poolManagerLookup) Ownable(msg.sender) {
        poolManager = IPoolManager(poolManagerLookup.value());
    }

    using StateLibrary for IPoolManager;

    /**
     * @inheritdoc IPlacer
     */
    function offer(Currency token, Currency quote, int24[] calldata ticks, uint256[] calldata amounts)
        external
        payable
    {
        uint256 n = amounts.length;
        if (n == 0) revert NoPositions();
        if (ticks.length != n + 1) revert TickAmountLengthMismatch(ticks.length, n);

        if (ticks[0] < TickMath.MIN_TICK) revert TickOutOfRange(ticks[0]);
        if (ticks[n] > TickMath.MAX_TICK) revert TickOutOfRange(ticks[n]);
        for (uint256 i = 1; i < ticks.length; i++) {
            if (ticks[i] <= ticks[i - 1]) revert TicksNotAscending(i, ticks[i - 1], ticks[i]);
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
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
        PoolId poolId = key.toId();

        int24 startingV4Tick = tokenIsCurrency0 ? ticks[0] : -ticks[0];
        uint160 startingSqrtPriceX96 = TickMath.getSqrtPriceAtTick(startingV4Tick);

        (uint160 existingSqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        if (existingSqrtPriceX96 == 0) {
            if (!tokenIsCurrency0) {
                startingSqrtPriceX96 = _maybeInteriorSqrt(key.currency0, ticks, amounts[0], startingSqrtPriceX96);
            }
            poolManager.initialize(key, startingSqrtPriceX96);
        }

        uint256 firstPositionId = positions.length;
        poolManager.unlock(abi.encodeCall(IFountainActions.offer, (key, ticks, amounts, tokenIsCurrency0)));

        emit Offered(msg.sender, token, quote, poolId, firstPositionId, n);
    }

    /**
     * @dev Seat every segment of the caller-described curve in one unlock.
     *      User segment [userTicks[i], userTicks[i+1]) with amount[i]
     *      seats a V4 position at [userTicks[i], userTicks[i+1]) when the
     *      token is currency0 (identity mapping), or at
     *      [-userTicks[i+1], -userTicks[i]) when the token is currency1
     *      (flipping under V4's price inversion). Net debits on both
     *      currencies are accumulated across positions and settled at
     *      the end. Out-of-range positions have zero delta on one side;
     *      the in-range starting segment may have a small delta on both
     *      sides (the interior-shift bootstrap path).
     *      Precondition: PoolManager unlocked to this contract.
     */
    function _offerUnlocked(
        PoolKey memory key,
        int24[] memory userTicks,
        uint256[] memory amounts,
        bool tokenIsCurrency0
    ) private {
        uint256 n = amounts.length;
        int256 totalOwed0;
        int256 totalOwed1;
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

            (BalanceDelta delta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: bytes32(0)
                }),
                ""
            );

            totalOwed0 += int256(delta.amount0());
            totalOwed1 += int256(delta.amount1());

            positions.push(Position({key: key, tickLower: tickLower, tickUpper: tickUpper}));
        }

        _settleOwedUnlocked(key.currency0, totalOwed0);
        _settleOwedUnlocked(key.currency1, totalOwed1);
    }

    /**
     * @dev Settle a non-positive owed amount against the PoolManager. If
     *      Fountain's balance can't cover it, skip — V4 will revert with
     *      {IPoolManager.CurrencyNotSettled} at unlock close, preserving
     *      the original error surface for genuinely-underfunded offers.
     *      Precondition: PoolManager unlocked to this contract.
     */
    function _settleOwedUnlocked(Currency currency, int256 owedSigned) private {
        if (owedSigned >= 0) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(-owedSigned);
        if (currency.isAddressZero()) {
            if (address(this).balance < owed) return;
            poolManager.sync(currency);
            poolManager.settle{value: owed}();
        } else {
            IERC20 erc = IERC20(Currency.unwrap(currency));
            if (erc.balanceOf(address(this)) < owed) return;
            poolManager.sync(currency);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            erc.transfer(address(poolManager), owed);
            poolManager.settle();
        }
    }

    /**
     * @dev In the flipped case, the boundary starting tick puts position 0
     *      at its upper edge — out-of-range, active liquidity zero, quoter
     *      dead zone. Shifting `startingSqrtPriceX96` down by a single
     *      sqrt-wei pushes it interior so position 0 contributes its `L`
     *      to active liquidity at genesis. The shift requires a few hundred
     *      wei of `quote` (currency0) to settle position 0's mixed deposit;
     *      use it iff Fountain holds enough, else fall back to the boundary.
     */
    function _maybeInteriorSqrt(Currency quote, int24[] calldata ticks, uint256 firstAmount, uint160 boundarySqrt)
        private
        view
        returns (uint160)
    {
        if (boundarySqrt == 0) return boundarySqrt;
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(-ticks[1]);
        uint128 firstL = _liquidity1(sqrtLower, boundarySqrt, firstAmount);
        if (firstL == 0) return boundarySqrt;
        uint160 interiorSqrt = boundarySqrt - 1;
        uint256 dustRequired = SqrtPriceMath.getAmount0Delta(interiorSqrt, boundarySqrt, firstL, true);
        uint256 available =
            quote.isAddressZero() ? address(this).balance : IERC20(Currency.unwrap(quote)).balanceOf(address(this));
        return available >= dustRequired ? interiorSqrt : boundarySqrt;
    }

    /**
     * @inheritdoc IFountainTaker
     */
    function positionsCount() external view returns (uint256) {
        return positions.length;
    }

    /**
     * @inheritdoc IFountainTaker
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
     * @inheritdoc IFountainTaker
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
            poolManager.getPositionInfo(poolId, address(this), tickLower, tickUpper, bytes32(0));
        (uint256 growth0Now, uint256 growth1Now) = poolManager.getFeeGrowthInside(poolId, tickLower, tickUpper);
        unchecked {
            amount0 = FullMath.mulDiv(growth0Now - growth0Last, liquidity, FixedPoint128.Q128);
            amount1 = FullMath.mulDiv(growth1Now - growth1Last, liquidity, FixedPoint128.Q128);
        }
    }

    /**
     * @inheritdoc IFountainTaker
     */
    function take(uint256 positionId) external {
        uint256[] memory ids = new uint256[](1);
        ids[0] = positionId;
        _takeMany(ids);
    }

    /**
     * @inheritdoc IFountainTaker
     */
    function take(uint256[] calldata ids) external {
        _takeMany(ids);
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
        poolManager.unlock(abi.encodeCall(IFountainActions.take, (ids)));
    }

    /**
     * @dev Take fees from a batch of Fountain-owned positions via zero-delta
     *      modifyLiquidity calls and pull them into Fountain's own balance.
     *      {owner} reclaims accumulated balance via {withdraw}.
     *      Precondition: PoolManager unlocked to this contract.
     */
    function _takeManyUnlocked(uint256[] memory ids) private {
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            Position storage p = positions[id];
            PoolKey memory key = p.key;
            int24 tickLower = p.tickLower;
            int24 tickUpper = p.tickUpper;
            (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: bytes32(0)
                }),
                ""
            );
            int128 fee0 = feesAccrued.amount0();
            int128 fee1 = feesAccrued.amount1();
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount0 = fee0 > 0 ? uint256(uint128(fee0)) : 0;
            // forge-lint: disable-next-line(unsafe-typecast)
            uint256 amount1 = fee1 > 0 ? uint256(uint128(fee1)) : 0;
            if (amount0 > 0) poolManager.take(key.currency0, address(this), amount0);
            if (amount1 > 0) poolManager.take(key.currency1, address(this), amount1);
            emit Taken(id, key.toId(), amount0, amount1);
        }
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Selector-dispatches on {IFountainActions}: either seats a batch
     *      of positions or iterates a batch of ids for fee take.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert InvalidUnlockCaller();
        bytes4 selector = bytes4(data[:4]);
        if (selector == IFountainActions.offer.selector) {
            (PoolKey memory key, int24[] memory userTicks, uint256[] memory amounts, bool tokenIsCurrency0) =
                abi.decode(data[4:], (PoolKey, int24[], uint256[], bool));
            _offerUnlocked(key, userTicks, amounts, tokenIsCurrency0);
        } else if (selector == IFountainActions.take.selector) {
            uint256[] memory ids = abi.decode(data[4:], (uint256[]));
            _takeManyUnlocked(ids);
        } else {
            revert UnknownSelector(selector);
        }
        return "";
    }

    /**
     * @notice Send `amount` of `currency` from Fountain's balance to `to`.
     *         Lets {owner} reclaim fees collected by {take} and any prefund
     *         the deployer dropped in to seed flipped-case bootstraps.
     * @dev    Owner-only. Reverts with {WithdrawFailed} if a native-ETH
     *         transfer is rejected by `to`. ERC-20 transfer failure
     *         surfaces the token's own revert.
     */
    function withdraw(Currency currency, uint256 amount, address to) external onlyOwner {
        if (currency.isAddressZero()) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert WithdrawFailed();
        } else {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(Currency.unwrap(currency)).transfer(to, amount);
        }
        emit Withdrawn(to, currency, amount);
    }

    /**
     * @notice Accept native ETH. Required so {take} can route ETH-side fees
     *         from the PoolManager into Fountain's balance, and so the
     *         deployer can prefund flipped-case ETH bootstraps with a
     *         plain transfer.
     */
    receive() external payable {}

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
     * @inheritdoc IOwnableMaker
     */
    function made(address owner_, uint256 variant) public view returns (bool exists, address home, bytes32 salt) {
        salt = keccak256(abi.encode(owner_, variant));
        home = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        exists = home.code.length > 0;
    }

    /**
     * @inheritdoc IOwnableMaker
     * @dev Must be called on the prototype. Calling on a clone reverts
     *      with {Unauthorized} — `msg.sender` semantics cannot be
     *      preserved across clone forwarding.
     */
    function make(uint256 variant) external returns (address instance) {
        if (address(this) != address(proto)) revert Unauthorized();
        (bool exists, address home, bytes32 salt) = made(msg.sender, variant);
        instance = home;
        if (!exists) {
            Clones.cloneDeterministic(address(proto), salt, 0);
            Fountain(payable(home)).zzInit(msg.sender);
            emit Made(msg.sender, variant, home);
        }
    }

    /**
     * @notice Initializer called by the prototype on a freshly deployed
     *         clone. Sets the clone's owner. Reverts with {Unauthorized}
     *         if called by anyone other than the prototype.
     */
    function zzInit(address owner_) public {
        if (msg.sender != address(proto)) revert Unauthorized();
        _transferOwnership(owner_);
    }
}
