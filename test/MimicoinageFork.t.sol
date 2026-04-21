// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {Mimicoinage} from "../src/Mimicoinage.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {Funder} from "./Funder.sol";
import {SwapRouter} from "./SwapRouter.sol";
import {Trader} from "./Trader.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage as Coinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
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
 * @notice Fork test against mainnet state. Deploys a fresh Fountain and a
 *         fresh Mimicoinage against the real PoolManagerLookup and Coinage
 *         factory, then launches mimics and reads the resulting pool
 *         state. Fee collection runs through {Fountain.collect} directly —
 *         Mimicoinage is a thin wrapper and exposes only the
 *         mimic→position mapping needed to resolve ids.
 *
 *         Run with:
 *           forge test --match-contract MimicoinageForkTest -f mainnet -vv
 *         or pin a block for reproducibility:
 *           FORK_BLOCK=24923365 forge test --match-contract MimicoinageForkTest -f mainnet -vv
 */
contract MimicoinageForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    Fountain internal fountain;
    Mimicoinage internal mimicoinage;
    SwapRouter internal router;
    Funder internal bot;

    function setUp() public override {
        super.setUp();

        bot = new Funder("bot");
        fountain = new Fountain(IAddressLookup(PoolManagerLookup), address(bot));
        bot.setFountain(fountain);
        mimicoinage = new Mimicoinage(Coinage(ICoinage), fountain);
        router = new SwapRouter(fountain.POOL_MANAGER());
    }

    function test_PredictMimicMatchesLaunch() public {
        string memory name = "USDCmimic";
        (bool exists, address predicted) = mimicoinage.predictMimic(IERC20Metadata(USDC), name);
        assertFalse(exists, "fresh Mimicoinage cannot have pre-existing mimics");
        assertTrue(predicted != address(0), "predicted address is zero");

        (IERC20Metadata mimic,) = mimicoinage.launch(IERC20Metadata(USDC), name);
        assertEq(address(mimic), predicted, "launched address differs from prediction");
    }

    function test_LaunchUSDC() public {
        (IERC20Metadata mimic,) = mimicoinage.launch(IERC20Metadata(USDC), "USDCmimic");

        assertEq(mimic.decimals(), IERC20Metadata(USDC).decimals(), "decimals must match original");
        assertEq(mimic.symbol(), "USDCx1", "symbol must be original.symbol + SUFFIX");
        assertTrue(mimicoinage.isMimic(IERC20(address(mimic))), "launched token not marked as mimic");

        // Pool is initialized at tick 0 (sqrtPriceX96 for tick 0 = 2**96).
        PoolId id = mimicoinage.poolIdOf(IERC20(address(mimic)));
        (uint160 sqrtPriceX96, int24 tick,,) = fountain.POOL_MANAGER().getSlot0(id);
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

        (IERC20Metadata hiMimic,) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        (IERC20Metadata loMimic,) = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");

        assertLt(uint160(address(hiMimic)), uint160(ffffff), "mimic of high lepton must sort below (token0)");
        assertGt(uint160(address(loMimic)), uint160(zeros), "mimic of low lepton must sort above (token1)");

        (uint160 hiSqrt, int24 hiTick,,) =
            fountain.POOL_MANAGER().getSlot0(mimicoinage.poolIdOf(IERC20(address(hiMimic))));
        (uint160 loSqrt, int24 loTick,,) =
            fountain.POOL_MANAGER().getSlot0(mimicoinage.poolIdOf(IERC20(address(loMimic))));

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
        (IERC20Metadata hiMimic,) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        (IERC20Metadata loMimic,) = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");

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
        (IERC20Metadata hiMimic,) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        (IERC20Metadata loMimic,) = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");

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

    /**
     * @notice A swap accrues fees on the input side of the position; Fountain
     *         routes them to its owner (the bot) on {collect}. Verifies both
     *         the {Fountain.pendingFees} forecast and the actual transfer.
     */
    function test_CollectRoutesFeesToOwner() public {
        // mimic sorts below ffffff → mimic is currency0, ffffff is currency1.
        // A zeroForOne=false swap spends currency1 (ffffff), so fees accrue on currency1.
        (IERC20Metadata mimic, uint256 positionId) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        PoolKey memory key = mimicoinage.poolKeyOf(IERC20(address(mimic)));

        uint128 amountIn = 1e18;
        Trader alice = new Trader("alice", router);
        deal(ffffff, address(alice), uint256(amountIn));
        alice.swap(key, false, amountIn);

        uint256[] memory ids = new uint256[](1);
        ids[0] = positionId;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.pendingFees(ids);
        assertEq(pending0[0], 0, "no fees should accrue on currency0 (mimic)");
        assertGt(pending1[0], 0, "fees should accrue on currency1 (ffffff) after a buy");

        uint256 expected = pending1[0];
        uint256 ownerBefore = IERC20(ffffff).balanceOf(address(bot));

        bot.collect(positionId);

        assertEq(
            IERC20(ffffff).balanceOf(address(bot)) - ownerBefore, expected, "OWNER received != pendingFees forecast"
        );

        (pending0, pending1) = fountain.pendingFees(ids);
        assertEq(pending0[0], 0, "residual currency0 fees after collect");
        assertEq(pending1[0], 0, "residual currency1 fees after collect");
    }

    /**
     * @notice Batch collect sweeps several mimic positions in one unlock. Two
     *         mimics accrue fees on opposite currencies (ffffff as currency1
     *         vs zeros as currency0); a single {Fountain.collect} pushes both
     *         forecasts to the owner.
     */
    function test_CollectBatchRoutesFeesToOwner() public {
        (IERC20Metadata hiMimic, uint256 hiId) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        (IERC20Metadata loMimic, uint256 loId) = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");

        PoolKey memory hiKey = mimicoinage.poolKeyOf(IERC20(address(hiMimic)));
        PoolKey memory loKey = mimicoinage.poolKeyOf(IERC20(address(loMimic)));

        uint128 amountIn = 1e18;
        Trader alice = new Trader("alice", router);
        Trader bobby = new Trader("bobby", router);
        deal(ffffff, address(alice), uint256(amountIn));
        deal(zeros, address(bobby), uint256(amountIn));

        // hi: spend ffffff (currency1) → fees on pending1; lo: spend zeros (currency0) → fees on pending0.
        alice.swap(hiKey, false, amountIn);
        bobby.swap(loKey, true, amountIn);

        uint256[] memory ids = new uint256[](2);
        ids[0] = hiId;
        ids[1] = loId;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.pendingFees(ids);
        assertGt(pending1[0], 0, "ffffff (currency1) fees should be pending on hi");
        assertGt(pending0[1], 0, "zeros (currency0) fees should be pending on lo");

        uint256 ffffffBefore = IERC20(ffffff).balanceOf(address(bot));
        uint256 zerosBefore = IERC20(zeros).balanceOf(address(bot));

        bot.collectBatch(ids);

        assertEq(IERC20(ffffff).balanceOf(address(bot)) - ffffffBefore, pending1[0], "bot ffffff delta != hi pending1");
        assertEq(IERC20(zeros).balanceOf(address(bot)) - zerosBefore, pending0[1], "bot zeros delta != lo pending0");

        (pending0, pending1) = fountain.pendingFees(ids);
        assertEq(pending0[0] + pending1[0] + pending0[1] + pending1[1], 0, "residual fees after batch collect");
    }

    /**
     * @notice {poolKeyOf} reverts with {UnknownMimic} for an unknown token.
     */
    function test_PoolKeyOfRevertsOnUnknownMimic() public {
        IERC20 bogus = IERC20(USDC);
        vm.expectRevert(abi.encodeWithSelector(Mimicoinage.UnknownMimic.selector, bogus));
        mimicoinage.poolKeyOf(bogus);
    }

    /**
     * @notice {poolIdOf} reverts with {UnknownMimic} for an unknown token.
     */
    function test_PoolIdOfRevertsOnUnknownMimic() public {
        IERC20 bogus = IERC20(USDC);
        vm.expectRevert(abi.encodeWithSelector(Mimicoinage.UnknownMimic.selector, bogus));
        mimicoinage.poolIdOf(bogus);
    }

    /**
     * @notice If the PoolKey was already initialized at the 1:1 genesis price
     *         (by someone else beating us to it benignly), {launch} skips the
     *         re-init and completes normally.
     */
    function test_LaunchIdempotentAtGenesisPrice() public {
        (, address predicted) = mimicoinage.predictMimic(IERC20Metadata(ffffff), "mimicFF");
        PoolKey memory key = _predictedPoolKey(IERC20Metadata(ffffff), "mimicFF");
        fountain.POOL_MANAGER().initialize(key, TickMath.getSqrtPriceAtTick(0));

        (IERC20Metadata mimic,) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        assertEq(address(mimic), predicted, "launched address != predicted");
        assertTrue(mimicoinage.isMimic(IERC20(address(mimic))), "mimic not registered");
    }

    /**
     * @notice A griefer that pre-initializes the target PoolKey at any price
     *         other than tick 0 blocks {launch} with {Fountain.PoolPreInitialized}.
     *         The workaround is to re-launch with a different `name`, which
     *         produces a fresh mimic address and a fresh PoolKey.
     */
    function test_LaunchRevertsOnPreInitializedPool() public {
        PoolKey memory key = _predictedPoolKey(IERC20Metadata(ffffff), "mimicFF");
        uint160 griefSqrt = TickMath.getSqrtPriceAtTick(100);
        fountain.POOL_MANAGER().initialize(key, griefSqrt);

        vm.expectRevert(abi.encodeWithSelector(Fountain.PoolPreInitialized.selector, griefSqrt));
        mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");

        // Re-launching under a different name yields a different PoolKey and succeeds.
        (IERC20Metadata escaped,) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF2");
        assertTrue(mimicoinage.isMimic(IERC20(address(escaped))), "rescue launch under new name failed");
    }

    /**
     * @notice Exercise every branch of {mimicsRange}: exact slice, tail
     *         clamp (`end > length`), offset past end (`offset >= length`),
     *         and empty count. Covers the enumeration + clamp math that
     *         rots silently if broken.
     */
    function test_MimicsRangeClampBranches() public {
        (IERC20Metadata m0,) = mimicoinage.launch(IERC20Metadata(ffffff), "mimicFF");
        (IERC20Metadata m1,) = mimicoinage.launch(IERC20Metadata(zeros), "mimicZZ");
        (IERC20Metadata m2,) = mimicoinage.launch(IERC20Metadata(USDC), "USDCmimic");
        assertEq(mimicoinage.mimicsCount(), 3, "count after three launches");

        // Full slice.
        IERC20Metadata[] memory all = mimicoinage.mimicsRange(0, 3);
        assertEq(all.length, 3, "full slice length");
        assertEq(address(all[0]), address(m0), "all[0]");
        assertEq(address(all[1]), address(m1), "all[1]");
        assertEq(address(all[2]), address(m2), "all[2]");

        // Tail clamp: end > length → returns existing tail only.
        IERC20Metadata[] memory tail = mimicoinage.mimicsRange(1, 10);
        assertEq(tail.length, 2, "tail clamp length");
        assertEq(address(tail[0]), address(m1), "tail[0]");
        assertEq(address(tail[1]), address(m2), "tail[1]");

        // Offset at end -> empty.
        assertEq(mimicoinage.mimicsRange(3, 5).length, 0, "offset == length should be empty");
        // Offset past end -> empty.
        assertEq(mimicoinage.mimicsRange(10, 5).length, 0, "offset past length should be empty");
        // Zero count -> empty.
        assertEq(mimicoinage.mimicsRange(0, 0).length, 0, "count == 0 should be empty");

        // Middle single element.
        IERC20Metadata[] memory mid = mimicoinage.mimicsRange(1, 1);
        assertEq(mid.length, 1, "middle slice length");
        assertEq(address(mid[0]), address(m1), "mid[0]");
    }

    /**
     * @dev Rebuild the {PoolKey} {launch} will compute for `(original, name)`
     *      using the predicted mimic CREATE2 address — lets a test pre-init
     *      the target pool before the mimic exists.
     */
    function _predictedPoolKey(IERC20Metadata original, string memory name) internal view returns (PoolKey memory) {
        (, address predicted) = mimicoinage.predictMimic(original, name);
        bool mimicIsToken0 = predicted < address(original);
        return PoolKey({
            currency0: Currency.wrap(mimicIsToken0 ? predicted : address(original)),
            currency1: Currency.wrap(mimicIsToken0 ? address(original) : predicted),
            fee: mimicoinage.FEE(),
            tickSpacing: mimicoinage.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
    }
}
