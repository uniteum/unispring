// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Mimicoinage} from "../src/Mimicoinage.sol";
import {SwapRouter} from "./SwapRouter.sol";
import {Trader} from "./Trader.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage as Coinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @notice Minimal V4Quoter interface — single-hop exact-input entrypoint.
 */
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

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
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address internal immutable V4Quoter;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address internal immutable ffffff;
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    address internal immutable zeros;

    Mimicoinage internal mimicoinage;
    SwapRouter internal router;

    constructor() {
        PoolManagerLookup = vm.envAddress("PoolManagerLookup");
        ICoinage = vm.envAddress("ICoinage");
        USDC = vm.envAddress("USDC");
        V4Quoter = vm.envAddress("V4Quoter");
        ffffff = vm.envAddress("ffffff");
        zeros = vm.envAddress("zeros");
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
        router = new SwapRouter(mimicoinage.POOL_MANAGER());
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

    /**
     * @notice Both orderings must initialize at the identical 1:1 spot price.
     *         `ffffff` is a high-address lepton (mimic sorts below → token0);
     *         `zeros` is a low-address lepton (mimic sorts above → token1).
     *         Sanity checks the ordering, then asserts both pools land at
     *         tick 0 with sqrtPriceX96 = 2**96.
     */
    function test_BothOrderingsLaunchAtIdenticalPrice() public {
        require(ffffff.code.length > 0, "ffffff lepton missing at forked block");
        require(zeros.code.length > 0, "zeros lepton missing at forked block");

        IERC20Metadata hiMimic = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        IERC20Metadata loMimic = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");

        assertLt(uint160(address(hiMimic)), uint160(ffffff), "mimic of high lepton must sort below (token0)");
        assertGt(uint160(address(loMimic)), uint160(zeros), "mimic of low lepton must sort above (token1)");

        (uint160 hiSqrt, int24 hiTick,,) =
            mimicoinage.POOL_MANAGER().getSlot0(mimicoinage.poolIdOf(IERC20(address(hiMimic))));
        (uint160 loSqrt, int24 loTick,,) =
            mimicoinage.POOL_MANAGER().getSlot0(mimicoinage.poolIdOf(IERC20(address(loMimic))));

        assertEq(hiTick, int24(0), "high-lepton pool must initialize at tick 0");
        assertEq(loTick, int24(0), "low-lepton pool must initialize at tick 0");
        assertEq(uint256(hiSqrt), FixedPoint96.Q96, "high-lepton pool sqrtPrice != 2**96");
        assertEq(uint256(loSqrt), FixedPoint96.Q96, "low-lepton pool sqrtPrice != 2**96");
        assertEq(hiSqrt, loSqrt, "spot prices must match across orderings");
    }

    /**
     * @notice Equivalent swaps across the two orderings must quote the same
     *         output. Buys `mimic` with `original` in each pool; the range
     *         geometry differs (mimic-above vs mimic-below) but the fee tier,
     *         tick spacing, and seated supply are identical, so outputs
     *         should match to sub-bp precision.
     */
    function test_QuotedOutputsMatchAcrossOrdering() public {
        IERC20Metadata hiMimic = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        IERC20Metadata loMimic = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");

        PoolKey memory hiKey = mimicoinage.poolKeyOf(IERC20(address(hiMimic)));
        PoolKey memory loKey = mimicoinage.poolKeyOf(IERC20(address(loMimic)));

        // Buy mimic with original:
        //   hi pool — mimic is token0, original is token1 → oneForZero (zeroForOne=false)
        //   lo pool — mimic is token1, original is token0 → zeroForOne=true
        uint128 amountIn = 1e18;
        IV4Quoter quoter = IV4Quoter(V4Quoter);

        (uint256 hiOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: hiKey, zeroForOne: false, exactAmount: amountIn, hookData: ""})
        );
        (uint256 loOut,) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({poolKey: loKey, zeroForOne: true, exactAmount: amountIn, hookData: ""})
        );

        assertGt(hiOut, 0, "high-lepton quote returned zero");
        assertGt(loOut, 0, "low-lepton quote returned zero");
        // Tolerance 0.01%: asymmetry comes from sqrt(1.0001)-1 vs 1-1/sqrt(1.0001),
        // which diverge by ~5e-5 of the gap at tick-spacing 1.
        assertApproxEqRel(hiOut, loOut, 1e14, "quoted outputs diverge across orderings");
    }

    /**
     * @notice Two sequential exact-input buys in each pool must match across
     *         orderings on BOTH buys — i.e. the second buy also prices
     *         symmetrically after the first advances pool state. Quoter is
     *         stateless, so this executes real swaps via persona traders.
     */
    function test_SequentialBuysMatchAcrossOrdering() public {
        IERC20Metadata hiMimic = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        IERC20Metadata loMimic = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");

        PoolKey memory hiKey = mimicoinage.poolKeyOf(IERC20(address(hiMimic)));
        PoolKey memory loKey = mimicoinage.poolKeyOf(IERC20(address(loMimic)));

        uint128 amountIn = 1e18;
        Trader alice = new Trader("alice", router);
        Trader bob = new Trader("bob", router);
        deal(ffffff, address(alice), uint256(amountIn) * 2);
        deal(zeros, address(bob), uint256(amountIn) * 2);

        uint256 hi1 = alice.swap(hiKey, false, amountIn);
        uint256 lo1 = bob.swap(loKey, true, amountIn);
        assertApproxEqRel(hi1, lo1, 1e14, "first buy: outputs diverge across orderings");

        uint256 hi2 = alice.swap(hiKey, false, amountIn);
        uint256 lo2 = bob.swap(loKey, true, amountIn);
        assertApproxEqRel(hi2, lo2, 1e14, "second buy: outputs diverge across orderings");

        // Sanity: price moved after the first buy, so the second buy gets less mimic.
        assertLt(hi2, hi1, "hi: second buy did not reflect advanced pool state");
        assertLt(lo2, lo1, "lo: second buy did not reflect advanced pool state");
    }
}
