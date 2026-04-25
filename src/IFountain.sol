// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title IFountain
 * @notice Minimal Fountain surface used by callers that only seat
 *         positions and never read fee/clone state. Lets factories like
 *         {Mimicoinage} depend on Fountain without pulling in its V4
 *         imports.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IFountain {
    /**
     * @notice Offer `token` for sale at the ticks you set, paired against
     *         `quote`. The `ticks` array partitions a "token/quote" price
     *         range into N = `amounts.length` segments; `amounts[i]` seats
     *         the segment bounded by `ticks[i]` and `ticks[i + 1]`
     *         single-sided in `token`. Trading fees accrue to the
     *         Fountain's owner. When `token` is an ERC-20 the caller must
     *         have approved the Fountain for the sum of `amounts`; when
     *         `token` is native ETH (`Currency.wrap(address(0))`) the
     *         caller must send that sum as `msg.value` — this is why
     *         `offer` is `payable`. The native-ETH-as-token path supports
     *         e.g. seating an ETH spoke against a hub in {Unispring};
     *         token-side ETH is unusual otherwise (most callers offer the
     *         scarce token and quote in ETH or a stablecoin).
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
        returns (uint256 firstPositionId);
}
