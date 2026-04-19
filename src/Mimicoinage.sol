// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
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
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title Mimicoinage
 * @notice Singleton factory that mints an ERC-20 pegged 1:1 against an
 *         original token and seats its entire supply into a single-tick
 *         Uniswap V4 position owned by this contract. The position is
 *         permanent — no function on this contract can decrease or unwind
 *         liquidity. {collect} forwards accrued swap fees to the immutable
 *         {OWNER}.
 * @dev    The mimic token carries the original's decimals so the raw
 *         sqrtPrice of 1 (tick 0) corresponds to a 1:1 human-unit peg.
 *         The pool uses {FEE} = 100 (0.01%), {TICK_SPACING} = 1, and no
 *         hook. Range is `[0, 1)` when the mimic sorts below the original
 *         and `[-1, 0)` when it sorts above — both place tick 0 at the edge
 *         of the range such that the position holds only the mimic at
 *         genesis.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Mimicoinage is IUnlockCallback {
    using StateLibrary for IPoolManager;

    string public constant VERSION = "0.2.0";

    /**
     * @notice Fixed raw supply minted for every mimic token. Sized to stay
     *         well below the `maxLiquidityPerTick` cap at `TICK_SPACING = 1`
     *         for any reasonable decimals.
     */
    uint128 public constant SUPPLY = 10 ** 27;

    /**
     * @notice Pool fee in hundredths of a bip (0.01%).
     */
    uint24 public constant FEE = 100;

    /**
     * @notice Pool tick spacing — one tick wide for maximum concentration.
     */
    int24 public constant TICK_SPACING = 1;

    /**
     * @notice Symbol suffix appended to the original token's symbol.
     */
    string public constant SUFFIX = "x1";

    /**
     * @notice The Uniswap V4 PoolManager, resolved from the `IAddressLookup`
     *         supplied at construction.
     */
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice The Coinage factory used to mint the mimic ERC-20.
     */
    ICoinage public immutable COINAGE;

    /**
     * @notice Recipient of swap fees collected by {collect}. Has no other
     *         authority: cannot decrease liquidity, cannot unwind the
     *         position, cannot pause. Set at construction and immutable.
     */
    address public immutable OWNER;

    /**
     * @notice Original token paired with each mimic, indexed by the mimic
     *         token address. Populated by {launch}; zero for unknown mimics.
     */
    mapping(IERC20 => IERC20) public originalOf;

    /**
     * @notice All mimics launched by this factory, in launch order. The
     *         auto-generated getter returns a single element by index; use
     *         {mimicsCount} and {mimicsRange} for bulk reads.
     */
    IERC20Metadata[] public mimics;

    /**
     * @notice Emitted when a mimic token is launched.
     */
    event Launch(IERC20Metadata indexed mimic, IERC20Metadata indexed original, PoolId indexed poolId);

    /**
     * @notice Emitted when {collect} forwards swap fees to {OWNER}.
     */
    event Collect(PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /**
     * @notice Thrown when {unlockCallback} is invoked by anyone other than the PoolManager.
     */
    error InvalidUnlockCaller();

    /**
     * @notice Thrown if liquidity computed from supply exceeds `uint128`.
     */
    error LiquidityOverflow();

    /**
     * @notice Thrown when {collect} is called with a mimic this factory did not launch.
     */
    error UnknownMimic(IERC20 mimic);

    /**
     * @notice Construct the singleton factory.
     * @param  poolManagerLookup Lookup for the chain-local PoolManager.
     * @param  coinage           The Coinage factory used to mint mimics.
     * @param  owner             Recipient of collected swap fees.
     */
    constructor(IAddressLookup poolManagerLookup, ICoinage coinage, address owner) {
        POOL_MANAGER = IPoolManager(poolManagerLookup.value());
        COINAGE = coinage;
        OWNER = owner;
    }

    /**
     * @notice Collect accrued swap fees for `mimic`'s position and forward
     *         them to {OWNER}. Permissionless — anyone can trigger the
     *         collection, but fees always route to {OWNER}. Reverts if
     *         `mimic` was not launched by this factory.
     * @param  mimic The mimic token whose position fees should be collected.
     */
    /**
     * @notice The number of mimics launched by this factory.
     */
    function mimicsCount() external view returns (uint256) {
        return mimics.length;
    }

    /**
     * @notice Return a contiguous slice of {mimics}. Clamps to the array
     *         bounds: passing an `offset` at or past the end returns an
     *         empty array; passing a `count` that runs past the end
     *         returns only the existing tail.
     * @param  offset Index of the first mimic to return.
     * @param  count  Maximum number of mimics to return.
     * @return slice  The requested mimic tokens, in launch order.
     */
    function mimicsRange(uint256 offset, uint256 count) external view returns (IERC20Metadata[] memory slice) {
        uint256 length = mimics.length;
        if (offset >= length) return new IERC20Metadata[](0);
        uint256 end = offset + count;
        if (end > length) end = length;
        slice = new IERC20Metadata[](end - offset);
        for (uint256 i = 0; i < slice.length; i++) {
            slice[i] = mimics[offset + i];
        }
    }

    /**
     * @notice Mint a mimic of `original` and seat its entire supply into a
     *         single-tick V4 position at the 1:1 edge. The position is
     *         permanent.
     * @param  original The reference token to peg against.
     * @param  name     Name for the newly minted mimic token.
     * @return mimic    The newly minted mimic token.
     */
    function launch(IERC20Metadata original, string calldata name) external returns (IERC20Metadata mimic) {
        uint8 decimals = original.decimals();
        string memory symbol = string.concat(original.symbol(), SUFFIX);
        mimic = COINAGE.make(name, symbol, decimals, SUPPLY, bytes32(0));
        originalOf[mimic] = original;
        mimics.push(mimic);

        bool mimicIsToken0 = address(mimic) < address(original);
        int24 tickLower = mimicIsToken0 ? int24(0) : int24(-1);
        int24 tickUpper = mimicIsToken0 ? int24(1) : int24(0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(mimicIsToken0 ? address(mimic) : address(original)),
            currency1: Currency.wrap(mimicIsToken0 ? address(original) : address(mimic)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        if (sqrtPriceX96 == 0) {
            POOL_MANAGER.initialize(key, TickMath.getSqrtPriceAtTick(0));
        }

        POOL_MANAGER.unlock(abi.encode(true, key, tickLower, tickUpper, mimicIsToken0));

        emit Launch(mimic, original, poolId);
    }

    function collect(IERC20 mimic) external {
        IERC20 original = originalOf[mimic];
        if (address(original) == address(0)) revert UnknownMimic(mimic);

        bool mimicIsToken0 = address(mimic) < address(original);
        int24 tickLower = mimicIsToken0 ? int24(0) : int24(-1);
        int24 tickUpper = mimicIsToken0 ? int24(1) : int24(0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(mimicIsToken0 ? address(mimic) : address(original)),
            currency1: Currency.wrap(mimicIsToken0 ? address(original) : address(mimic)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        POOL_MANAGER.unlock(abi.encode(false, key, tickLower, tickUpper, false));
    }

    /**
     * @inheritdoc IUnlockCallback
     * @dev Dispatches on the boolean flag in `data`: `true` funds the
     *      launch position, `false` collects fees to {OWNER}.
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidUnlockCaller();
        (bool isLaunch, PoolKey memory key, int24 tickLower, int24 tickUpper, bool mimicIsToken0) =
            abi.decode(data, (bool, PoolKey, int24, int24, bool));

        if (isLaunch) {
            _fund(key, tickLower, tickUpper, mimicIsToken0);
        } else {
            _collect(key, tickLower, tickUpper);
        }
        return "";
    }

    /**
     * @dev Fund the launch position single-sided with {SUPPLY} of the mimic.
     */
    function _fund(PoolKey memory key, int24 tickLower, int24 tickUpper, bool mimicIsToken0) private {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            mimicIsToken0 ? _liquidity0(sqrtLower, sqrtUpper, SUPPLY) : _liquidity1(sqrtLower, sqrtUpper, SUPPLY);

        (BalanceDelta delta,) = POOL_MANAGER.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
            }),
            ""
        );

        Currency currency = mimicIsToken0 ? key.currency0 : key.currency1;
        int128 amount = mimicIsToken0 ? delta.amount0() : delta.amount1();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 owed = uint256(uint128(-amount));

        POOL_MANAGER.sync(currency);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(Currency.unwrap(currency)).transfer(address(POOL_MANAGER), owed);
        POOL_MANAGER.settle();
    }

    /**
     * @dev Collect fees from the Mimicoinage-owned position via a zero-delta
     *      modifyLiquidity and forward them to {OWNER}.
     */
    function _collect(PoolKey memory key, int24 tickLower, int24 tickUpper) private {
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

        if (amount0 > 0) POOL_MANAGER.take(key.currency0, OWNER, amount0);
        if (amount1 > 0) POOL_MANAGER.take(key.currency1, OWNER, amount1);

        emit Collect(key.toId(), amount0, amount1);
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
