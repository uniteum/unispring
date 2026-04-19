// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {Mimicoinage} from "../src/Mimicoinage.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Deploy the Mimicoinage singleton via Nick's CREATE2 deployer.
 * @dev    Configuration comes from environment variables:
 *           PoolManagerLookup — IAddressLookup for PoolManager
 *           ICoinage          — Coinage factory used to mint mimic tokens
 *           MimicoinageOwner  — recipient of collected swap fees
 *
 * Usage:
 * forge script script/MimicoinageDeploy.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract MimicoinageDeploy is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        IAddressLookup poolManagerLookup = IAddressLookup(vm.envAddress("PoolManagerLookup"));
        ICoinage coinage = ICoinage(vm.envAddress("ICoinage"));
        address owner = vm.envAddress("MimicoinageOwner");

        console2.log("poolManagerLookup:", address(poolManagerLookup));
        console2.log("coinage          :", address(coinage));
        console2.log("owner            :", owner);

        bytes memory initCode =
            abi.encodePacked(type(Mimicoinage).creationCode, abi.encode(poolManagerLookup, coinage, owner));
        address predicted = vm.computeCreate2Address(bytes32(0), keccak256(initCode), NICK);
        console2.log("predicted        :", predicted);

        if (predicted.code.length == 0) {
            vm.startBroadcast();
            (bool ok,) = NICK.call(abi.encodePacked(bytes32(0), initCode));
            vm.stopBroadcast();
            require(ok, "create2 deploy failed");
            console2.log("deployed         :", predicted);
        } else {
            console2.log("already deployed");
        }
    }
}
