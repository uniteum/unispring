// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Deploy the Unispring prototype via Nick's CREATE2 deployer, then
 *         create a clone for the given hub token and seed its hub pool.
 * @dev    All configuration comes from environment variables — no in-source
 *         defaults. Required:
 *           PoolManagerLookup — per-chain `IAddressLookup` resolving the V4
 *                               PoolManager
 *           HUB               — address of the already-deployed hub token
 *           HubTickFloor      — hub starting tick floor (int)
 *           HubAmount         — wei amount of hub to transfer to the clone
 *                               address before calling `make`
 *
 *         The broadcaster must hold at least `HubAmount` of the hub token.
 *
 * Usage:
 * forge script script/UnispringDeploy.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract UnispringDeploy is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManagerLookupAddr = vm.envAddress("PoolManagerLookup");
        address hubAddr = vm.envAddress("HUB");
        int256 tickFloorRaw = vm.envInt("HubTickFloor");
        // Tick values are always within int24 range by construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 hubTickFloor = int24(tickFloorRaw);
        uint256 hubAmount = vm.envUint("HubAmount");

        int24 tickLower = TickMath.MIN_TICK + 1;
        int24 tickUpper = -hubTickFloor;

        console2.log("pmLookup    :", poolManagerLookupAddr);
        console2.log("hub         :", hubAddr);
        console2.log("tickFloor   :", int256(hubTickFloor));
        console2.log("hubAmount   :", hubAmount);

        // 1. Compute the deterministic prototype CREATE2 address.
        bytes memory initCode =
            abi.encodePacked(type(Unispring).creationCode, abi.encode(IAddressLookup(poolManagerLookupAddr)));
        address predictedProto = vm.computeCreate2Address(bytes32(0), keccak256(initCode), NICK);
        console2.log("predicted proto:", predictedProto);

        // 2. Deploy the prototype via Nick's CREATE2 factory (once).
        if (predictedProto.code.length == 0) {
            vm.startBroadcast();
            (bool ok,) = NICK.call(abi.encodePacked(bytes32(0), initCode));
            vm.stopBroadcast();
            require(ok, "create2 deploy failed");
            console2.log("deployed proto:", predictedProto);
        } else {
            console2.log("proto already deployed");
        }

        Unispring proto = Unispring(payable(predictedProto));

        // 3. Predict the clone address and fund it, then call make (seeds in zzInit).
        (bool exists, address home,) = proto.made(IERC20(hubAddr), tickLower, tickUpper);
        console2.log("predicted clone:", home);

        if (!exists) {
            uint256 currentBalance = IERC20(hubAddr).balanceOf(home);
            if (currentBalance < hubAmount) {
                uint256 topUp = hubAmount - currentBalance;
                vm.startBroadcast();
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(hubAddr).transfer(home, topUp);
                vm.stopBroadcast();
                console2.log("funded clone with hub:", topUp);
            }

            vm.startBroadcast();
            proto.make(IERC20(hubAddr), tickLower, tickUpper);
            vm.stopBroadcast();
            console2.log("clone created and hub pool seeded");
        } else {
            console2.log("clone already deployed");
        }
    }
}
