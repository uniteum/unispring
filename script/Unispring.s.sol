// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {ProtoScript} from "crucible/script/Proto.s.sol";

/**
 * @notice Deploy the Unispring contract.
 * @dev Usage: forge script script/Unispring.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract UnispringProto is ProtoScript {
    function name() internal pure override returns (string memory) {
        return "UnispringProto";
    }

    function creationCode() internal pure override returns (bytes memory) {
        return type(Unispring).creationCode;
    }
}
