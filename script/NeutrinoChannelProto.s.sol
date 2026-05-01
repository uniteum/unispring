// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {NeutrinoChannel} from "../src/NeutrinoChannel.sol";
import {ProtoScript} from "crucible/script/Proto.s.sol";

/**
 * @notice Deploy the NeutrinoChannel prototype via Nick's CREATE2 deployer.
 *
 * Usage:
 * forge script script/NeutrinoChannelProto.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract NeutrinoChannelProto is ProtoScript {
    function name() internal pure override returns (string memory) {
        return "NeutrinoChannel";
    }

    function creationCode() internal pure override returns (bytes memory) {
        return type(NeutrinoChannel).creationCode;
    }
}
