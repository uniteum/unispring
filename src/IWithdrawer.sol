// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IWithdrawer
 * @notice Surface for pulling a currency balance held by a contract out
 *         to its owner. Centered on {withdraw}; {Withdrawn} lets observers
 *         track how much has been pulled in each currency over time.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IWithdrawer {
    /**
     * @notice Emitted when {withdraw} sends a balance to the owner.
     * @param  currency The currency withdrawn (`address(0)` for native ETH).
     * @param  amount   The amount sent.
     */
    event Withdrawn(address indexed currency, uint256 amount);

    /**
     * @notice Pull `amount` of `currency` from the contract's balance and
     *         send it to its owner. Owner-only.
     */
    function withdraw(address currency, uint256 amount) external;
}
