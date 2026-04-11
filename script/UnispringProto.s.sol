// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Deploy Unispring via Nick's CREATE2 deployer, salt-mining the hub's
 *         Lepton salt so the resulting hub address has many leading `f` bytes.
 * @dev    Environment variables (all optional except LeptonProto):
 *           LeptonProto     — Lepton prototype address (required)
 *           HubName         — hub token name, default "Uniteum 1"
 *           HubSymbol       — hub token symbol, default "UT1"
 *           HubSupply       — hub token supply in wei, default 10_000_000 ether
 *           HubTickFloor    — hub's starting tick floor, default -60000
 *           HubMinFs        — minimum number of leading `f` hex chars, default 4
 *           HubMaxTries     — max salt attempts, default 1_000_000
 *
 *         Usage: forge script script/UnispringProto.s.sol:UnispringProto -f $chain \
 *                    --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract UnispringProto is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address leptonProto = vm.envAddress("LeptonProto");
        string memory hubName = vm.envOr("HubName", string("Uniteum 1"));
        string memory hubSymbol = vm.envOr("HubSymbol", string("UT1"));
        uint256 hubSupply = vm.envOr("HubSupply", uint256(10_000_000 ether));
        int256 tickFloorRaw = vm.envOr("HubTickFloor", int256(-60_000));
        // Tick values are always within int24 range by construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 hubTickFloor = int24(tickFloorRaw);
        uint256 minFs = vm.envOr("HubMinFs", uint256(4));
        uint256 maxTries = vm.envOr("HubMaxTries", uint256(1_000_000));

        console2.log("leptonProto:", leptonProto);
        console2.log("hubName    :", hubName);
        console2.log("hubSymbol  :", hubSymbol);
        console2.log("hubSupply  :", hubSupply);
        console2.log("tickFloor  :", int256(hubTickFloor));
        console2.log("minFs      :", minFs);

        ICoinage lepton = ICoinage(leptonProto);

        // 1. Mine the Lepton salt. For each candidate, compute the Unispring
        //    CREATE2 address the resulting init code would produce, ask Lepton
        //    what hub address that Unispring would mint, and check the prefix.
        bytes32 winningSalt;
        bytes memory winningInitCode;
        address predictedUnispring;
        address predictedHub;
        bool found;

        for (uint256 i = 0; i < maxTries; i++) {
            bytes32 salt = bytes32(i);
            bytes memory initCode = abi.encodePacked(
                type(Unispring).creationCode, abi.encode(leptonProto, hubName, hubSymbol, hubSupply, salt, hubTickFloor)
            );
            address unispringAddr = vm.computeCreate2Address(bytes32(0), keccak256(initCode), NICK);
            (, address hubAddr,) = lepton.made(unispringAddr, hubName, hubSymbol, hubSupply, salt);
            if (_leadingFs(hubAddr) >= minFs) {
                winningSalt = salt;
                winningInitCode = initCode;
                predictedUnispring = unispringAddr;
                predictedHub = hubAddr;
                found = true;
                break;
            }
        }

        require(found, "no salt found within maxTries - raise HubMaxTries or lower HubMinFs");

        console2.log("winning salt (uint):", uint256(winningSalt));
        console2.log("predicted Unispring:", predictedUnispring);
        console2.log("predicted HUB      :", predictedHub);

        // 2. Deploy Unispring via Nick's CREATE2 factory (once).
        if (predictedUnispring.code.length == 0) {
            vm.startBroadcast();
            (bool ok,) = NICK.call(abi.encodePacked(bytes32(0), winningInitCode));
            vm.stopBroadcast();
            require(ok, "create2 deploy failed");
            console2.log("deployed Unispring:", predictedUnispring);
        } else {
            console2.log("Unispring already deployed");
        }

        // 3. Seed the hub pool. Idempotent-ish: if already seeded, we skip.
        Unispring unispring = Unispring(payable(predictedUnispring));
        if (PoolId.unwrap(unispring.hubPool()) == bytes32(0)) {
            vm.startBroadcast();
            unispring.seedHub();
            vm.stopBroadcast();
            console2.log("hub pool seeded");
        } else {
            console2.log("hub pool already seeded");
        }
    }

    /**
     * @dev Count leading `f` hex characters in `addr`.
     */
    function _leadingFs(address addr) private pure returns (uint256 count) {
        uint160 a = uint160(addr);
        // 40 hex chars total; iterate from the top nibble down.
        for (uint256 i = 0; i < 40; i++) {
            uint256 nibble = (a >> (156 - i * 4)) & 0xf;
            if (nibble != 0xf) break;
            count++;
        }
    }
}

