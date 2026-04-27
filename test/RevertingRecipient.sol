// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title RevertingRecipient
 * @notice Test helper that rejects any incoming ETH transfer by reverting
 *         with a custom error. Used to verify that callers bubble the
 *         original revert data instead of swallowing it.
 */
contract RevertingRecipient {
    error Nope(string reason);

    receive() external payable {
        revert Nope("nope");
    }
}
