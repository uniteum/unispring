// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {TestToken} from "./TestToken.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @title ForkBase
 * @notice Shared base for mainnet fork tests. Resolves chain-local
 *         addresses from `.env` (names mirror the env keys exactly),
 *         selects the mainnet fork (pinned via `FORK_BLOCK` if set, else
 *         HEAD), and verifies the uniteum singletons exist at that block.
 *         Subclasses override {setUp} and must call `super.setUp()` first.
 */
contract ForkBase is Test {
    address internal immutable PoolManagerLookup;
    address internal immutable ICoinage;
    address internal immutable USDC;
    address internal immutable V4Quoter;
    address internal immutable ffffff;
    address internal immutable zeros;

    constructor() {
        PoolManagerLookup = vm.envAddress("PoolManagerLookup");
        ICoinage = vm.envAddress("ICoinage");
        USDC = vm.envAddress("USDC");
        V4Quoter = vm.envAddress("V4Quoter");
        ffffff = vm.envAddress("ffffff");
        zeros = vm.envAddress("zeros");
    }

    function setUp() public virtual {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork("mainnet");
        } else {
            vm.createSelectFork("mainnet", forkBlock);
        }

        require(PoolManagerLookup.code.length > 0, "PoolManagerLookup missing at forked block");
        require(ICoinage.code.length > 0, "ICoinage missing at forked block");
    }

    /**
     * @notice Deploy a fresh {TestToken} that sorts strictly between the
     *         fixed `zeros` and `ffffff` leptons — guaranteeing both the
     *         flip case (paired against `ffffff`, token = currency0) and
     *         no-flip case (paired against `zeros`, token = currency1) are
     *         reachable from a single token instance.
     */
    function _makeToken(string memory name, string memory symbol, uint8 decimals) internal returns (TestToken token) {
        token = new TestToken(name, symbol, decimals);
        require(address(token) > zeros, "token must sort above zeros");
        require(address(token) < ffffff, "token must sort below ffffff");
    }
}
