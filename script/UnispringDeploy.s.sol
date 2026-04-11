// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Deploy Unispring via Nick's CREATE2 deployer, salt-mining the hub's
 *         Lepton salt over a caller-supplied range so the resulting hub address
 *         has many leading `f` bytes.
 * @dev    All configuration comes from environment variables — no in-source
 *         defaults. Required:
 *           IPoolManagerLookup — per-chain `IAddressLookup` resolving the V4
 *                                PoolManager
 *           ICoinage      — Lepton prototype address (same value as the ICoinage
 *                           export used by the other scripts)
 *           HubName       — hub token name
 *           HubSymbol     — hub token symbol
 *           HubSupply     — hub token supply in wei
 *           HubTickFloor  — hub starting tick floor (int)
 *           HubMinFs      — minimum leading `f` hex chars the hub address must have
 *           HubSaltMin    — inclusive lower bound of the salt search range
 *           HubSaltMax    — exclusive upper bound of the salt search range
 *
 * Usage:
 * forge script script/UnispringDeploy.s.sol -f $chain --private-key $tx_key --broadcast --verify --delay 10 --retries 10
 */
contract UnispringDeploy is Script {
    address constant NICK = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        address poolManagerLookupAddr = vm.envAddress("PoolManagerLookup");
        address coinageAddr = vm.envAddress("ICoinage");
        string memory hubName = vm.envString("HubName");
        string memory hubSymbol = vm.envString("HubSymbol");
        uint256 hubSupply = vm.envUint("HubSupply");
        int256 tickFloorRaw = vm.envInt("HubTickFloor");
        // Tick values are always within int24 range by construction.
        // forge-lint: disable-next-line(unsafe-typecast)
        int24 hubTickFloor = int24(tickFloorRaw);
        uint256 minFs = vm.envUint("HubMinFs");
        uint256 saltMin = vm.envUint("HubSaltMin");
        uint256 saltMax = vm.envUint("HubSaltMax");

        require(saltMax > saltMin, "HubSaltMax must be > HubSaltMin");

        console2.log("pmLookup   :", poolManagerLookupAddr);
        console2.log("coinage    :", coinageAddr);
        console2.log("hubName    :", hubName);
        console2.log("hubSymbol  :", hubSymbol);
        console2.log("hubSupply  :", hubSupply);
        console2.log("tickFloor  :", int256(hubTickFloor));
        console2.log("minFs      :", minFs);
        console2.log("saltMin    :", saltMin);
        console2.log("saltMax    :", saltMax);

        // EIP-1167 minimal proxy init code hash for a clone whose implementation
        // is the Lepton prototype at `coinageAddr`. Matches OpenZeppelin Clones.
        bytes32 cloneInitCodeHash = keccak256(
            abi.encodePacked(
                hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", coinageAddr, hex"5af43d82803e903d91602b57fd5bf3"
            )
        );

        // 1. Mine the Lepton salt over [saltMin, saltMax). For each candidate,
        //    compute the Unispring CREATE2 address the resulting init code would
        //    produce, replicate Lepton's clone-address math off-chain (so the
        //    loop makes no RPC calls), and check the prefix.
        //
        //    Solidity never frees memory within a call, so every iteration's
        //    fresh `initCode` buffer would OOM a long search. We snapshot the
        //    free-memory pointer and reset it each iteration — the per-iteration
        //    allocations are strictly scoped, so this is safe.
        bytes32 winningSalt;
        bytes memory winningInitCode;
        address predictedUnispring;
        address predictedHub;
        bool found;

        uint256 memSnapshot;
        // forge-lint: disable-next-line(asm-keccak256)
        assembly {
            memSnapshot := mload(0x40)
        }

        for (uint256 i = saltMin; i < saltMax; i++) {
            bytes32 salt = bytes32(i);
            bytes memory initCode = abi.encodePacked(
                type(Unispring).creationCode,
                abi.encode(
                    IAddressLookup(poolManagerLookupAddr),
                    coinageAddr,
                    hubName,
                    hubSymbol,
                    hubSupply,
                    salt,
                    hubTickFloor
                )
            );
            address unispringAddr = vm.computeCreate2Address(bytes32(0), keccak256(initCode), NICK);
            bytes32 create2Salt = keccak256(abi.encode(unispringAddr, hubName, hubSymbol, hubSupply, salt));
            address hubAddr = vm.computeCreate2Address(create2Salt, cloneInitCodeHash, coinageAddr);
            if (_leadingFs(hubAddr) >= minFs) {
                winningSalt = salt;
                predictedUnispring = unispringAddr;
                predictedHub = hubAddr;
                found = true;
                break;
            }
            assembly {
                mstore(0x40, memSnapshot)
            }
        }

        // Rebuild the winning init code after the mining loop so it survives
        // the per-iteration memory reset.
        if (found) {
            winningInitCode = abi.encodePacked(
                type(Unispring).creationCode,
                abi.encode(
                    IAddressLookup(poolManagerLookupAddr),
                    coinageAddr,
                    hubName,
                    hubSymbol,
                    hubSupply,
                    winningSalt,
                    hubTickFloor
                )
            );
        }

        require(found, "no salt found in [HubSaltMin, HubSaltMax) - widen the range or lower HubMinFs");

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
