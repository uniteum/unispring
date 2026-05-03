// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICoinage} from "icoinage/ICoinage.sol";
import {NeutrinoChannel} from "../src/NeutrinoChannel.sol";
import {NeutrinoSource} from "../src/NeutrinoSource.sol";
import {Script, console2} from "forge-std/Script.sol";
import {Manifold} from "../src/Manifold.sol";

/**
 * @notice Deploy the NeutrinoSource prototype via Nick's CREATE2 deployer.
 * @dev    Configuration comes from environment variables:
 *           ICoinage        — the Coinage prototype
 *           NeutrinoChannelProto — the NeutrinoChannel prototype
 *           ManifoldProto  — the Manifold prototype
 *
 * Usage:
 * forge script script/NeutrinoSourceProto.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract NeutrinoSourceProto is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        ICoinage minter = ICoinage(vm.envAddress("ICoinage"));
        NeutrinoChannel channel = NeutrinoChannel(vm.envAddress("NeutrinoChannelProto"));
        Manifold manifold = Manifold(payable(vm.envAddress("ManifoldProto")));

        console2.log("minter:", address(minter));
        console2.log("channel:", address(channel));
        console2.log("manifold:", address(manifold));

        // Compute the deterministic prototype CREATE2 address.
        bytes memory initCode =
            abi.encodePacked(type(NeutrinoSource).creationCode, abi.encode(manifold, channel, minter));
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
