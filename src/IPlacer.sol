// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/**
 * @title IPlacer
 * @notice Minimal placer surface used by callers that only seat
 *         positions and never read fee/clone state. Lets callers
 *         depend on a placer without pulling in V4 imports.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IPlacer {
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
     * @notice Thrown when {offer} is called with a native-ETH token. Only
     *         ERC-20 tokens may seat positions; the quote side may still be
     *         native ETH.
     */
    error TokenIsNative();

    /**
     * @notice Offer `token` for sale at the ticks you set, paired against
     *         `quote`. The `ticks` array partitions a "token/quote" price
     *         range into N = `amounts.length` segments; `amounts[i]` seats
     *         the segment bounded by `ticks[i]` and `ticks[i + 1]`
     *         single-sided in `token`. Trading fees accrue to the
     *         Fountain's owner. The caller must have approved the Fountain
     *         for the sum of `amounts`. `token` must be an ERC-20; passing
     *         native ETH reverts with {TokenIsNative}. The quote side may
     *         still be native ETH.
     * @dev    `ticks[0]` is the *intended* starting price: an uninitialized
     *         pool is initialized at that price, but if the pool already
     *         exists Fountain proceeds with whatever spot price it finds.
     *         Outcome depends on where that spot sits relative to
     *         `ticks[0]` (in user/token-per-quote terms):
     *
     *         - spot at-or-below `ticks[0]`: every position is fully above
     *           spot, single-sided in `token`, and seats normally. The
     *           pool just starts at a lower price than the caller intended
     *           and the bonding curve activates as buyers push spot up
     *           into the range.
     *
     *         - spot above `ticks[0]`: at least the first position would
     *           span or sit below spot and demand the quote currency,
     *           which Fountain does not settle. The PoolManager unlock
     *           reverts with {CurrencyNotSettled} (V4-named) and the
     *           transaction unwinds with no state change.
     *
     *         A would-be griefer that front-runs `initialize` therefore
     *         only locks the {PoolKey} when they pick a price strictly
     *         above `ticks[0]`. A below-`ticks[0]` front-run is silently
     *         absorbed; an above-`ticks[0]` one can be undone by anyone
     *         (no liquidity in the path) by walking spot back down with a
     *         1-wei swap before re-calling {offer}.
     * @param  token   The currency whose supply seats the positions
     *                 (`Currency.wrap(address(0))` for native ETH).
     * @param  quote   The quote currency (`Currency.wrap(address(0))`
     *                 for native ETH).
     * @param  ticks   Strictly ascending ticks in "token/quote" price
     *                 semantics. Length N + 1 for N positions.
     * @param  amounts Per-segment token amounts. Length N, all non-zero.
     */
    function offer(Currency token, Currency quote, int24[] calldata ticks, uint256[] calldata amounts) external;
}
