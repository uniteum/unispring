// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Deploy Unispring via Nick's CREATE2 deployer against an
 *         externally-minted hub, fund it with the configured hub amount, and
 *         seed the hub pool.
 * @dev    All configuration comes from environment variables — no in-source
 *         defaults. Required:
 *           PoolManagerLookup — per-chain `IAddressLookup` resolving the V4
 *                               PoolManager
 *           HUB               — address of the already-deployed hub token
 *           HubTickFloor      — hub starting tick floor (int)
 *           HubAmount         — wei amount of hub to transfer into Unispring
 *                               before calling `seedHub`
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

        console2.log("pmLookup    :", poolManagerLookupAddr);
        console2.log("hub         :", hubAddr);
        console2.log("tickFloor   :", int256(hubTickFloor));
        console2.log("hubAmount   :", hubAmount);

        // 1. Compute the deterministic Unispring CREATE2 address. No salt mining:
        //    the init code is fixed by (lookup, hub, hubTickFloor) and the salt
        //    is always zero.
        bytes memory initCode = abi.encodePacked(
            type(Unispring).creationCode,
            abi.encode(IAddressLookup(poolManagerLookupAddr), IERC20(hubAddr), hubTickFloor)
        );
        address predictedUnispring = vm.computeCreate2Address(bytes32(0), keccak256(initCode), NICK);
        console2.log("predicted Unispring:", predictedUnispring);

        // 2. Deploy Unispring via Nick's CREATE2 factory (once).
        if (predictedUnispring.code.length == 0) {
            vm.startBroadcast();
            (bool ok,) = NICK.call(abi.encodePacked(bytes32(0), initCode));
            vm.stopBroadcast();
            require(ok, "create2 deploy failed");
            console2.log("deployed Unispring:", predictedUnispring);
        } else {
            console2.log("Unispring already deployed");
        }

        Unispring unispring = Unispring(payable(predictedUnispring));

        // 3. Seed the hub pool. Idempotent-ish: if already seeded, we skip.
        if (PoolId.unwrap(unispring.hubPool()) == bytes32(0)) {
            // Top up Unispring to `hubAmount` of hub tokens before seeding.
            uint256 currentBalance = IERC20(hubAddr).balanceOf(predictedUnispring);
            if (currentBalance < hubAmount) {
                uint256 topUp = hubAmount - currentBalance;
                vm.startBroadcast();
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(hubAddr).transfer(predictedUnispring, topUp);
                vm.stopBroadcast();
                console2.log("funded Unispring with hub:", topUp);
            }

            vm.startBroadcast();
            unispring.seedHub();
            vm.stopBroadcast();
            console2.log("hub pool seeded");
        } else {
            console2.log("hub pool already seeded");
        }
    }
}
