// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Mimicoinage} from "../src/Mimicoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Collector
 * @notice Test persona that is both the configured {Mimicoinage.OWNER}
 *         (fee recipient) and the party that pokes {Mimicoinage.collect}.
 *         Collect is permissionless so these roles do not have to coincide,
 *         but fusing them here keeps the flow simple: `bot.collect(mimic)`
 *         triggers the sweep and `bot`'s ERC-20 balance reflects the take.
 * @dev    The Mimicoinage reference is wired post-construction via
 *         {setMimicoinage} because the factory takes this contract's address
 *         as its `owner` — the deploy order is Collector → Mimicoinage →
 *         wire-back. Standalone for now; rebase onto crucible's `User.sol`
 *         once the `erc20`/`strings` submodules are available here.
 */
contract Collector {
    string public name;
    Mimicoinage public mimicoinage;

    constructor(string memory name_) {
        name = name_;
        console.log("%s born %s", name_, address(this));
    }

    /**
     * @notice Bind this Collector to the Mimicoinage whose {OWNER} is this
     *         contract. Called once from test `setUp`.
     */
    function setMimicoinage(Mimicoinage m) public {
        mimicoinage = m;
    }

    /**
     * @notice Trigger fee collection for a single mimic's position.
     */
    function collect(IERC20 mimic) public {
        mimicoinage.collect(mimic);
    }

    /**
     * @notice Trigger fee collection for several positions in one unlock.
     */
    function collectBatch(IERC20[] memory mimics) public {
        mimicoinage.collect(mimics);
    }
}
