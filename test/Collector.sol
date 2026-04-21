// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Mimicoinage} from "../src/Mimicoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {console} from "forge-std/console.sol";

/**
 * @title Collector
 * @notice Test persona that pokes {Mimicoinage.collect}. Collection is
 *         permissionless — fees always route to {Mimicoinage.OWNER}
 *         regardless of the caller — so a Collector distinct from the
 *         owner makes that invariant legible in tests.
 * @dev    Standalone for now. Rebase onto crucible's `User.sol` once the
 *         `erc20`/`strings` submodules are available here.
 */
contract Collector {
    string public name;
    Mimicoinage public immutable MIMICOINAGE;

    constructor(string memory name_, Mimicoinage mimicoinage) {
        name = name_;
        MIMICOINAGE = mimicoinage;
        console.log("%s born %s", name_, address(this));
    }

    /**
     * @notice Trigger fee collection for a single mimic's position.
     */
    function collect(IERC20 mimic) public {
        MIMICOINAGE.collect(mimic);
    }

    /**
     * @notice Trigger fee collection for several positions in one unlock.
     */
    function collectBatch(IERC20[] memory mimics) public {
        MIMICOINAGE.collect(mimics);
    }
}
