// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {Unispring} from "../src/Unispring.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Deploy the Unispring prototype via Nick's CREATE2 deployer.
 * @dev    Configuration comes from environment variables:
 *           Fountain — deployed Fountain that will seat every position
 *                      funded through this Unispring. Unispring mirrors
 *                      this Fountain's `POOL_MANAGER`, `FEE`, and `OWNER`.
 *
 * Usage:
 * forge script script/UnispringProto.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract UnispringProto is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        Fountain fountain = Fountain(vm.envAddress("Fountain"));

        console2.log("fountain:", address(fountain));

        // Compute the deterministic prototype CREATE2 address.
        bytes memory initCode = abi.encodePacked(type(Unispring).creationCode, abi.encode(fountain));
        address predictedProto = vm.computeCreate2Address(bytes32(0), keccak256(initCode), NICK);
        console2.log("predicted proto:", predictedProto);

        // Deploy the prototype via Nick's CREATE2 factory (once).
        if (predictedProto.code.length == 0) {
            vm.startBroadcast();
            (bool ok,) = NICK.call(abi.encodePacked(bytes32(0), initCode));
            vm.stopBroadcast();
            require(ok, "create2 deploy failed");
            console2.log("deployed proto:", predictedProto);
        } else {
            console2.log("proto already deployed");
        }
    }
}
