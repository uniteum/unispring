// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Deploy the Fountain prototype via Nick's CREATE2 deployer.
 *         The prototype is a Bitsy factory: clones are deployed per-caller
 *         via {Fountain.make}. Only the prototype is deployed here.
 * @dev    Configuration comes from environment variables:
 *           PoolManagerLookup — lookup resolving the chain-local Uniswap V4
 *                               PoolManager.
 *
 * Usage:
 * forge script script/FountainDeploy.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract FountainDeploy is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        IAddressLookup poolManagerLookup = IAddressLookup(vm.envAddress("PoolManagerLookup"));

        console2.log("poolManagerLookup:", address(poolManagerLookup));
        console2.log("pm      :", poolManagerLookup.value());

        bytes memory initCode = abi.encodePacked(type(Fountain).creationCode, abi.encode(poolManagerLookup));
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
