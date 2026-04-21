// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Funder
 * @notice Test persona that is both the configured {Fountain.OWNER}
 *         (fee recipient) and the party that pokes {Fountain.fund} and
 *         {Fountain.collect}. Fund is permissionless so these roles do
 *         not have to coincide, but fusing them here keeps the flow
 *         simple: `bot.fund(...)` approves + funds, and fees land on
 *         `bot`'s balance on `bot.collect(...)`.
 */
contract Funder {
    string public name;
    Fountain public fountain;

    constructor(string memory name_) {
        name = name_;
        console.log("%s born %s", name_, address(this));
    }

    /**
     * @notice Bind this Funder to the Fountain whose {OWNER} is this
     *         contract. Called once from test `setUp`.
     */
    function setFountain(Fountain f) external {
        fountain = f;
    }

    /**
     * @notice Approve the Fountain for the sum of `amounts` then fund.
     */
    function fund(IERC20 token, address quote, int24 tickSpacing, int24[] memory ticks, uint256[] memory amounts)
        external
        returns (uint256 firstPositionId)
    {
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        token.approve(address(fountain), total);
        firstPositionId = fountain.fund(token, quote, tickSpacing, ticks, amounts);
    }

    /**
     * @notice Collect a single position's fees through the Fountain.
     */
    function collect(uint256 id) external {
        fountain.collect(id);
    }

    /**
     * @notice Batch-collect several positions in one unlock.
     */
    function collectBatch(uint256[] memory ids) external {
        fountain.collect(ids);
    }
}
