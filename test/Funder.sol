// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Funder
 * @notice Test persona that is both the {Fountain.taker} of its own clone
 *         (fee recipient) and the party that pokes {Fountain.offer} and
 *         {Fountain.take}. Offer is permissionless so these roles do
 *         not have to coincide, but fusing them here keeps the flow
 *         simple: `bot.offer(...)` approves + offers, and fees land on
 *         `bot`'s balance on `bot.take(...)`.
 */
contract Funder {
    string public name;
    Fountain public fountain;

    constructor(string memory name_) {
        name = name_;
        console.log("%s born %s", name_, address(this));
    }

    /**
     * @notice Deploy this Funder's Fountain clone via the prototype. The
     *         clone's {Fountain.taker} is set to this contract. Called
     *         once from test `setUp`.
     */
    function makeFountain(Fountain proto) external {
        fountain = proto.make();
    }

    /**
     * @notice Approve the Fountain for the sum of `amounts` then offer.
     */
    function offer(IERC20 token, address quote, int24 tickSpacing, int24[] memory ticks, uint256[] memory amounts)
        external
        returns (uint256 firstPositionId)
    {
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        token.approve(address(fountain), total);
        firstPositionId = fountain.offer(token, quote, tickSpacing, ticks, amounts);
    }

    /**
     * @notice Take a single position's fees through the Fountain.
     */
    function take(uint256 id) external {
        fountain.take(id);
    }

    /**
     * @notice Batch-take several positions in one unlock.
     */
    function takeBatch(uint256[] memory ids) external {
        fountain.take(ids);
    }
}
