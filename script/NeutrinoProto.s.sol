// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICoinage} from "ierc20/ICoinage.sol";
import {Neutrino} from "../src/Neutrino.sol";
import {NeutrinoMaker} from "../src/NeutrinoMaker.sol";
import {Script, console2} from "forge-std/Script.sol";
import {Unispring} from "../src/Unispring.sol";

/**
 * @notice Deploy the Neutrino prototype via Nick's CREATE2 deployer.
 * @dev    Configuration comes from environment variables:
 *           ICoinage       — the Lepton prototype
 *           NeutrinoMaker  — the NeutrinoMaker prototype
 *           UnispringProto — the Unispring prototype
 *
 * Usage:
 * forge script script/NeutrinoProto.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract NeutrinoProto is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        ICoinage lepton = ICoinage(vm.envAddress("ICoinage"));
        NeutrinoMaker maker = NeutrinoMaker(vm.envAddress("NeutrinoMaker"));
        Unispring unispring = Unispring(payable(vm.envAddress("UnispringProto")));

        console2.log("lepton:", address(lepton));
        console2.log("maker:", address(maker));
        console2.log("unispring:", address(unispring));

        // Compute the deterministic prototype CREATE2 address.
        bytes memory initCode = abi.encodePacked(type(Neutrino).creationCode, abi.encode(lepton, maker, unispring));
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
