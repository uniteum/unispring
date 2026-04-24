// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "./Fountain.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @title Mimicoinage
 * @notice Thin factory that mints an ERC-20 pegged 1:1 against an original
 *         token and seats its entire supply as a single-tick segment in
 *         {FOUNTAIN}. All fee machinery — {Fountain.take},
 *         {Fountain.untaken}, {Fountain.owner} — lives on Fountain;
 *         Mimicoinage only records the mimic→position mapping and exposes
 *         the pool parameters needed to look up pool state.
 * @dev    The mimic token carries the original's decimals so the raw price
 *         of 1 at tick 0 corresponds to a 1:1 human-unit peg. Each position
 *         uses {FEE} = 100 (0.01%), {TICK_SPACING} = 1, and no hook. The
 *         user-semantic range is `[0, 1)`; Fountain flips and negates into
 *         V4-native ticks internally when the mimic sorts above the
 *         original, so both orderings seat only the mimic at genesis with
 *         tick 0 at the edge of the V4 range.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Mimicoinage {
    string public constant VERSION = "0.3.0";

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
     * @notice The Fountain that holds each mimic's single-tick position
     *         and routes its swap fees to {Fountain.owner}. Callers use
     *         {positionIdOf} to resolve a mimic to its Fountain position
     *         id for direct take / untaken queries.
     */
    Fountain public immutable FOUNTAIN;

    /**
     * @notice The Coinage factory used to mint the mimic ERC-20.
     */
    ICoinage public immutable COINAGE;

    /**
     * @notice Original token paired with each mimic, indexed by the mimic
     *         token address. Populated by {mimic}; zero for unknown mimics.
     */
    mapping(IERC20 => IERC20) public originalOf;

    /**
     * @notice Fountain position id backing each mimic, indexed by the mimic
     *         token address. Populated by {mimic}; meaningful only for
     *         addresses in {originalOf}.
     */
    mapping(IERC20 => uint256) public positionIdOf;

    /**
     * @notice All mimics minted by this factory, in mint order. The
     *         auto-generated getter returns a single element by index; use
     *         {mimicsCount} and {mimicsSlice} for bulk reads.
     */
    IERC20Metadata[] public mimics;

    /**
     * @notice Emitted when a mimic token is minted.
     */
    event Mimicked(
        IERC20Metadata indexed mimic, IERC20Metadata indexed original, PoolId indexed poolId, uint256 positionId
    );

    /**
     * @notice Thrown when {poolKeyOf} or {poolIdOf} is called with a mimic
     *         this factory did not mint.
     */
    error UnknownMimic(IERC20 mimic);

    /**
     * @notice Construct the singleton factory.
     * @param  fountain The Fountain that will hold mimic positions and
     *                  forward their swap fees.
     * @param  coinage  The Coinage factory used to mint mimics.
     */
    constructor(Fountain fountain, ICoinage coinage) {
        FOUNTAIN = fountain;
        COINAGE = coinage;
    }

    /**
     * @notice The number of mimics minted by this factory.
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
     * @return slice  The requested mimic tokens, in mint order.
     */
    function mimicsSlice(uint256 offset, uint256 count) external view returns (IERC20Metadata[] memory slice) {
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
     * @notice Whether `token` was minted by this factory as a mimic.
     * @param  token Any address.
     * @return True if `token` appears in {originalOf}.
     */
    function isMimic(IERC20 token) external view returns (bool) {
        return address(originalOf[token]) != address(0);
    }

    /**
     * @notice Rebuild the Uniswap V4 {PoolKey} used by `token`'s position.
     *         Useful for direct reads against the PoolManager (e.g. via
     *         `StateLibrary`). Reverts on unknown mimics.
     * @param  token A mimic minted by this factory.
     * @return key   The pool key with sorted currencies and this factory's
     *               fee/tickSpacing/hooks constants.
     */
    function poolKeyOf(IERC20 token) public view returns (PoolKey memory key) {
        IERC20 original = originalOf[token];
        if (address(original) == address(0)) revert UnknownMimic(token);
        bool mimicIsToken0 = address(token) < address(original);
        key = PoolKey({
            currency0: Currency.wrap(mimicIsToken0 ? address(token) : address(original)),
            currency1: Currency.wrap(mimicIsToken0 ? address(original) : address(token)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    /**
     * @notice Shortcut for `poolKeyOf(token).toId()`. Reverts on unknown
     *         mimics.
     * @param  token A mimic minted by this factory.
     * @return id    The derived Uniswap V4 pool id.
     */
    function poolIdOf(IERC20 token) external view returns (PoolId id) {
        id = poolKeyOf(token).toId();
    }

    /**
     * @notice Predict the address of the mimic that {mimic} would create
     *         for `(original, name)`. Lets a UI show the future token
     *         address (and whether it already exists) before any gas is
     *         spent.
     * @param  original The reference token that would be pegged against.
     * @param  name     Name that would be passed to {mimic}.
     * @return exists   True if the mimic has already been deployed.
     * @return token    Deterministic address of the mimic.
     */
    function predictMimic(IERC20Metadata original, string calldata name)
        external
        view
        returns (bool exists, address token)
    {
        uint8 decimals = original.decimals();
        string memory symbol = string.concat(original.symbol(), SUFFIX);
        (exists, token,) = COINAGE.made(address(this), name, symbol, decimals, SUPPLY, bytes32(0));
    }

    /**
     * @notice Mint a mimic of `original` and seat its entire supply as a
     *         single-tick segment in {FOUNTAIN} at the 1:1 edge. The
     *         segment spans user ticks `[0, 1)`; Fountain handles the
     *         V4-native tick flip when the mimic sorts above `original`.
     *         The position is permanent.
     * @param  original   The reference token to peg against.
     * @param  name       Name for the newly minted mimic token.
     * @return token      The newly minted mimic token.
     * @return positionId The Fountain position id seated by this call;
     *                    also available as {positionIdOf}(`token`).
     */
    function mimic(IERC20Metadata original, string calldata name)
        external
        returns (IERC20Metadata token, uint256 positionId)
    {
        uint8 decimals = original.decimals();
        string memory symbol = string.concat(original.symbol(), SUFFIX);
        token = COINAGE.make(name, symbol, decimals, SUPPLY, bytes32(0));
        IERC20 mimicErc = IERC20(address(token));
        originalOf[mimicErc] = original;
        mimics.push(token);

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        mimicErc.approve(address(FOUNTAIN), SUPPLY);

        int24[] memory ticks = new int24[](2);
        ticks[0] = 0;
        ticks[1] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SUPPLY;

        positionId = FOUNTAIN.offer(mimicErc, address(original), TICK_SPACING, ticks, amounts);
        positionIdOf[mimicErc] = positionId;

        emit Mimicked(token, original, poolKeyOf(mimicErc).toId(), positionId);
    }
}
