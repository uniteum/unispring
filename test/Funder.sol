// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain, Position} from "../src/Fountain.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Funder
 * @notice Test persona that is both the {Fountain.owner} of its own clone
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
     *         clone's {Fountain.owner} is set to this contract. Called
     *         once from test `setUp`.
     */
    function makeFountain(Fountain proto) external {
        fountain = Fountain(payable(proto.make(0)));
    }

    /**
     * @notice Approve the Fountain for the sum of `amounts` (when `token`
     *         is an ERC-20) and forward `msg.value` (when `token` is
     *         native ETH), then offer.
     */
    function offer(Currency token, Currency quote, int24[] memory ticks, uint256[] memory amounts) external payable {
        uint256 total;
        for (uint256 i = 0; i < amounts.length; i++) {
            total += amounts[i];
        }
        if (!token.isAddressZero()) {
            IERC20(Currency.unwrap(token)).approve(address(fountain), total);
        }
        fountain.offer{value: msg.value}(token, quote, ticks, amounts);
    }

    /**
     * @notice Take a single position's fees through the Fountain, then
     *         sweep both of the position's currencies into this Funder.
     *         Take pulls fees from the PoolManager into Fountain;
     *         withdraw routes them on to the owner.
     */
    function take(uint256 id) external {
        fountain.take(id);
        Position memory p = fountain.positionsSlice(id, 1)[0];
        _sweep(p.key.currency0);
        _sweep(p.key.currency1);
    }

    /**
     * @notice Batch-take several positions in one unlock and sweep each
     *         position's currencies into this Funder.
     */
    function takeBatch(uint256[] memory ids) external {
        fountain.take(ids);
        for (uint256 i = 0; i < ids.length; i++) {
            Position memory p = fountain.positionsSlice(ids[i], 1)[0];
            _sweep(p.key.currency0);
            _sweep(p.key.currency1);
        }
    }

    /**
     * @notice Withdraw `amount` of `currency` from Fountain to this Funder.
     *         Thin pass-through for tests that drive withdraw directly.
     */
    function withdraw(Currency currency, uint256 amount) external {
        fountain.withdraw(currency, amount, address(this));
    }

    receive() external payable {}

    function _sweep(Currency c) private {
        uint256 bal =
            c.isAddressZero() ? address(fountain).balance : IERC20(Currency.unwrap(c)).balanceOf(address(fountain));
        if (bal > 0) fountain.withdraw(c, bal, address(this));
    }
}
