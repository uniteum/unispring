// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {Currency} from "v4-core/types/Currency.sol";

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

    /**
     * @notice Pull `amount` of `currency` from `fountain`. The
     *         RevertingRecipient must already be `fountain.owner()`.
     */
    function pull(Fountain fountain, Currency currency, uint256 amount) external {
        fountain.withdraw(currency, amount);
    }
}
