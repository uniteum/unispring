// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Mimicoinage} from "../src/Mimicoinage.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage as Coinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

/**
 * @notice Fork test against mainnet state. Deploys a fresh Mimicoinage
 *         against the real PoolManagerLookup and Coinage factory, then
 *         launches a mimic of USDC and reads the resulting pool state.
 *         Deploys fresh rather than using the already-deployed singleton
 *         so the test exercises the current source.
 *
 *         Run with:
 *           forge test --match-contract MimicoinageForkTest -f mainnet -vv
 *         or pin a block for reproducibility:
 *           FORK_BLOCK=24915800 forge test --match-contract MimicoinageForkTest -f mainnet -vv
 */
contract MimicoinageForkTest is Test {
    using StateLibrary for IPoolManager;

    /// @dev Loaded from `.env`; names mirror the env keys exactly.
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address internal immutable PoolManagerLookup;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address internal immutable ICoinage;
    address internal immutable USDC;

    Mimicoinage internal mimicoinage;

    constructor() {
        PoolManagerLookup = vm.envAddress("PoolManagerLookup");
        ICoinage = vm.envAddress("ICoinage");
        USDC = vm.envAddress("USDC");
    }

    function setUp() public {
        uint256 forkBlock = vm.envOr("FORK_BLOCK", uint256(0));
        if (forkBlock == 0) {
            vm.createSelectFork("mainnet");
        } else {
            vm.createSelectFork("mainnet", forkBlock);
        }

        require(PoolManagerLookup.code.length > 0, "PoolManagerLookup missing at forked block");
        require(ICoinage.code.length > 0, "ICoinage missing at forked block");

        mimicoinage = new Mimicoinage(IAddressLookup(PoolManagerLookup), Coinage(ICoinage), address(this));
    }

    function test_PredictMimicMatchesLaunch() public {
        string memory name = "USDCmimic";
        (bool exists, address predicted) = mimicoinage.predictMimic(IERC20Metadata(USDC), name);
        assertFalse(exists, "fresh Mimicoinage cannot have pre-existing mimics");
        assertTrue(predicted != address(0), "predicted address is zero");

        IERC20Metadata mimic = mimicoinage.launch(IERC20Metadata(USDC), name);
        assertEq(address(mimic), predicted, "launched address differs from prediction");
    }

    function test_LaunchUSDC() public {
        IERC20Metadata mimic = mimicoinage.launch(IERC20Metadata(USDC), "USDCmimic");

        assertEq(mimic.decimals(), IERC20Metadata(USDC).decimals(), "decimals must match original");
        assertTrue(mimicoinage.isMimic(IERC20(address(mimic))), "launched token not marked as mimic");

        // Pool is initialized at tick 0 (sqrtPriceX96 for tick 0 = 2**96).
        PoolId id = mimicoinage.poolIdOf(IERC20(address(mimic)));
        (uint160 sqrtPriceX96, int24 tick,,) = mimicoinage.POOL_MANAGER().getSlot0(id);
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");

        // Entire supply is seated in the position — Mimicoinage holds nothing.
        assertEq(IERC20(address(mimic)).balanceOf(address(mimicoinage)), 0, "supply should be in V4, not in factory");
    }
}
