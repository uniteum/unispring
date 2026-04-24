// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "./Fountain.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @title Mimicoinage
 * @notice Thin factory that mints an ERC-20 pegged 1:1 against an original
 *         currency (ERC-20 or native ETH) and seats its entire supply as a
 *         single-tick segment in {FOUNTAIN}. All fee machinery — {Fountain.take},
 *         {Fountain.untaken}, {Fountain.owner} — lives on Fountain;
 *         Mimicoinage only records the mimic→position mapping and exposes
 *         the pool parameters needed to look up pool state.
 * @dev    The mimic token carries the original's decimals (18 for native
 *         ETH) so the raw price of 1 at tick 0 corresponds to a 1:1
 *         human-unit peg. Each position
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
     *         and routes its swap fees to {Fountain.owner}.
     */
    Fountain public immutable FOUNTAIN;

    /**
     * @notice The Coinage factory used to mint the mimic ERC-20.
     */
    ICoinage public immutable COINAGE;

    /**
     * @notice Original currency paired with each mimic, indexed by the mimic
     *         token address. Populated by {mimic}; meaningful only for
     *         mimics that satisfy {isMimic} (since `Currency.wrap(address(0))`
     *         is itself a valid native-ETH original).
     */
    mapping(IERC20Metadata => Currency) public originalOf;

    /**
     * @notice Whether `token` was minted by this factory as a mimic.
     *         Populated by {mimic}; the auto-generated getter doubles as
     *         the public existence check.
     */
    mapping(IERC20Metadata => bool) public isMimic;

    /**
     * @notice All mimics minted by this factory, in mint order. The
     *         auto-generated getter returns a single element by index; use
     *         {mimicsCount} and {mimicsSlice} for bulk reads.
     */
    IERC20Metadata[] public mimics;

    /**
     * @notice Emitted when a mimic token is minted.
     * @param  mimic       The newly minted ERC-20.
     * @param  original    The original currency the mimic is pegged against
     *                     (`Currency.wrap(address(0))` for native ETH).
     */
    event Mimicked(IERC20Metadata indexed mimic, Currency indexed original);

    /**
     * @notice Thrown when {poolKeyOf} or {poolIdOf} is called with a mimic
     *         this factory did not mint.
     */
    error UnknownMimic(IERC20Metadata mimic);

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
     * @notice Rebuild the Uniswap V4 {PoolKey} used by `token`'s position.
     *         Useful for direct reads against the PoolManager (e.g. via
     *         `StateLibrary`). Reverts on unknown mimics.
     * @param  token A mimic minted by this factory.
     * @return key   The pool key with sorted currencies and this factory's
     *               fee/tickSpacing/hooks constants.
     */
    function poolKeyOf(IERC20Metadata token) public view returns (PoolKey memory key) {
        if (!isMimic[token]) revert UnknownMimic(token);
        Currency mimicCurrency = Currency.wrap(address(token));
        Currency original = originalOf[token];
        bool mimicIsToken0 = mimicCurrency < original;
        key = PoolKey({
            currency0: mimicIsToken0 ? mimicCurrency : original,
            currency1: mimicIsToken0 ? original : mimicCurrency,
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
    function poolIdOf(IERC20Metadata token) external view returns (PoolId id) {
        id = poolKeyOf(token).toId();
    }

    /**
     * @notice Predict the address of the mimic that {mimic} would create
     *         for `(original, name)`. Lets a UI show the future token
     *         address (and whether it already exists) before any gas is
     *         spent.
     * @param  original The reference currency that would be pegged against
     *                  (`Currency.wrap(address(0))` for native ETH).
     * @param  name     Name that would be passed to {mimic}.
     * @return exists   True if the mimic has already been deployed.
     * @return token    Deterministic address of the mimic.
     */
    function predictMimic(Currency original, string calldata name) external view returns (bool exists, address token) {
        (uint8 decimals, string memory symbol) = _mimicMetadata(original);
        (exists, token,) = COINAGE.made(address(this), name, symbol, decimals, SUPPLY, bytes32(0));
    }

    /**
     * @notice Mint a mimic of `original` and seat its entire supply as a
     *         single-tick segment in {FOUNTAIN} at the 1:1 edge. The
     *         segment spans user ticks `[0, 1)`; Fountain handles the
     *         V4-native tick flip when the mimic sorts above `original`.
     *         The position is permanent.
     * @param  original   The reference currency to peg against
     *                    (`Currency.wrap(address(0))` for native ETH; the
     *                    mimic is minted with 18 decimals and `"ETH"` as
     *                    its symbol prefix in that case).
     * @param  name       Name for the newly minted mimic token.
     * @return token      The newly minted mimic token.
     */
    function mimic(Currency original, string calldata name) external returns (IERC20Metadata token) {
        (uint8 decimals, string memory symbol) = _mimicMetadata(original);
        token = COINAGE.make(name, symbol, decimals, SUPPLY, bytes32(0));
        IERC20Metadata mimicErc = IERC20Metadata(address(token));
        originalOf[mimicErc] = original;
        isMimic[mimicErc] = true;
        mimics.push(token);

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        mimicErc.approve(address(FOUNTAIN), SUPPLY);

        int24[] memory ticks = new int24[](2);
        ticks[0] = 0;
        ticks[1] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = SUPPLY;

        FOUNTAIN.offer(Currency.wrap(address(mimicErc)), original, ticks, amounts);

        emit Mimicked(token, original);
    }

    /**
     * @dev Resolve the decimals and symbol-prefix used to mint a mimic of
     *      `original`. Native ETH (`address(0)`) has no on-chain metadata,
     *      so the mimic uses 18 decimals and `"ETH"` as its symbol prefix
     *      to match the conventional human-unit semantics.
     */
    function _mimicMetadata(Currency original) private view returns (uint8 decimals, string memory symbol) {
        if (original.isAddressZero()) {
            decimals = 18;
            symbol = string.concat("ETH", SUFFIX);
        } else {
            IERC20Metadata orig = IERC20Metadata(Currency.unwrap(original));
            decimals = orig.decimals();
            symbol = string.concat(orig.symbol(), SUFFIX);
        }
    }
}
