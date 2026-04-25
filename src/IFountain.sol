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
     * @notice Seat a batch of single-sided positions for `token` against
     *         `quote`. See {Fountain.offer} for the full semantics.
     */
    function offer(Currency token, Currency quote, int24[] calldata ticks, uint256[] calldata amounts)
        external
        payable
        returns (uint256 firstPositionId);
}
