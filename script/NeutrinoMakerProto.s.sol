// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {NeutrinoMaker} from "../src/NeutrinoMaker.sol";
import {ProtoScript} from "crucible/script/Proto.s.sol";

/**
 * @notice Deploy the NeutrinoMaker prototype via Nick's CREATE2 deployer.
 *
 * Usage:
 * forge script script/NeutrinoMakerProto.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract NeutrinoMakerProto is ProtoScript {
    function name() internal pure override returns (string memory) {
        return "NeutrinoMaker";
    }

    function creationCode() internal pure override returns (bytes memory) {
        return type(NeutrinoMaker).creationCode;
    }
}
