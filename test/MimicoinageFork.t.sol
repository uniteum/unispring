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
 *         factory, then mints mimics and reads the resulting pool
 *         state. Fee take runs through {Fountain.take} directly —
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
        Fountain proto = new Fountain(IAddressLookup(PoolManagerLookup));
        bot.makeFountain(proto);
        fountain = bot.fountain();
        mimicoinage = new Mimicoinage(fountain, Coinage(ICoinage));
        router = new SwapRouter(fountain.POOL_MANAGER());
    }

    function test_PredictMimicMatchesMimic() public {
        string memory name = "USDCmimic";
        (bool exists, address predicted) = mimicoinage.predictMimic(Currency.wrap(USDC), name);
        assertFalse(exists, "fresh Mimicoinage cannot have pre-existing mimics");
        assertTrue(predicted != address(0), "predicted address is zero");

        IERC20Metadata mimic = mimicoinage.mimic(Currency.wrap(USDC), name);
        assertEq(address(mimic), predicted, "minted address differs from prediction");
    }

    function test_MimicUSDC() public {
        IERC20Metadata mimic = mimicoinage.mimic(Currency.wrap(USDC), "USDCmimic");

        assertEq(mimic.decimals(), IERC20Metadata(USDC).decimals(), "decimals must match original");
        assertEq(mimic.symbol(), "USDCx1", "symbol must be original.symbol + SUFFIX");
        assertTrue(mimicoinage.isMimic(IERC20Metadata(address(mimic))), "minted token not marked as mimic");

        // Pool is initialized at tick 0 (sqrtPriceX96 for tick 0 = 2**96).
        PoolId id = _poolKeyOf(IERC20Metadata(address(mimic))).toId();
        (uint160 sqrtPriceX96, int24 tick,,) = fountain.POOL_MANAGER().getSlot0(id);
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");

        // Entire supply is seated in the position — Mimicoinage holds nothing.
        assertEq(
            IERC20Metadata(address(mimic)).balanceOf(address(mimicoinage)), 0, "supply should be in V4, not in factory"
        );
    }

    /**
     * @notice Native ETH as the original: Mimicoinage falls back to "ETH" as
     *         the symbol prefix and 18 decimals (no on-chain metadata to read),
     *         registers the mimic, and seats it in a Fountain position whose
     *         `currency0` is `address(0)`.
     */
    function test_MimicNativeETH() public {
        IERC20Metadata mimic = mimicoinage.mimic(Currency.wrap(address(0)), "ETHmimic");

        assertEq(mimic.decimals(), uint8(18), "native mimic must have 18 decimals");
        assertEq(mimic.symbol(), "ETHx1", "native mimic symbol must be ETHx1");
        assertTrue(mimicoinage.isMimic(IERC20Metadata(address(mimic))), "minted mimic not registered");
        assertEq(
            Currency.unwrap(mimicoinage.originalOf(IERC20Metadata(address(mimic)))),
            address(0),
            "originalOf must point to native ETH"
        );

        // Mimic is a contract address (> 0), ETH sorts below: ETH = currency0, mimic = currency1.
        PoolKey memory key = _poolKeyOf(IERC20Metadata(address(mimic)));
        assertEq(Currency.unwrap(key.currency0), address(0), "ETH is currency0");
        assertEq(Currency.unwrap(key.currency1), address(mimic), "mimic is currency1");

        // Pool initialized at tick 0; entire mimic supply seated in Fountain position.
        (uint160 sqrtPriceX96, int24 tick,,) = fountain.POOL_MANAGER().getSlot0(key.toId());
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertEq(
            IERC20Metadata(address(mimic)).balanceOf(address(mimicoinage)), 0, "supply should be in V4, not in factory"
        );
        assertEq(fountain.positionsCount(), 1, "mimic must seat exactly one Fountain position");
    }

    /**
     * @notice Both orderings must initialize at the identical 1:1 spot price.
     *         `ffffff` is a high-address lepton (mimic sorts below → token0);
     *         `zeros` is a low-address lepton (mimic sorts above → token1).
     *         Sanity checks the ordering, then asserts both pools land at
     *         tick 0 with sqrtPriceX96 = 2**96.
     */
    function test_BothOrderingsMimicAtIdenticalPrice() public {
        require(ffffff.code.length > 0, "ffffff lepton missing at forked block");
        require(zeros.code.length > 0, "zeros lepton missing at forked block");

        IERC20Metadata hiMimic = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");
        IERC20Metadata loMimic = mimicoinage.mimic(Currency.wrap(zeros), "mimicZZ");

        assertLt(uint160(address(hiMimic)), uint160(ffffff), "mimic of high lepton must sort below (token0)");
        assertGt(uint160(address(loMimic)), uint160(zeros), "mimic of low lepton must sort above (token1)");

        (uint160 hiSqrt, int24 hiTick,,) =
            fountain.POOL_MANAGER().getSlot0(_poolKeyOf(IERC20Metadata(address(hiMimic))).toId());
        (uint160 loSqrt, int24 loTick,,) =
            fountain.POOL_MANAGER().getSlot0(_poolKeyOf(IERC20Metadata(address(loMimic))).toId());

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
        IERC20Metadata hiMimic = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");
        IERC20Metadata loMimic = mimicoinage.mimic(Currency.wrap(zeros), "mimicZZ");

        PoolKey memory hiKey = _poolKeyOf(IERC20Metadata(address(hiMimic)));
        PoolKey memory loKey = _poolKeyOf(IERC20Metadata(address(loMimic)));

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
        IERC20Metadata hiMimic = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");
        IERC20Metadata loMimic = mimicoinage.mimic(Currency.wrap(zeros), "mimicZZ");

        PoolKey memory hiKey = _poolKeyOf(IERC20Metadata(address(hiMimic)));
        PoolKey memory loKey = _poolKeyOf(IERC20Metadata(address(loMimic)));

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
     *         routes them to its taker (the bot) on {take}. Verifies both
     *         the {Fountain.untaken} forecast and the actual transfer.
     */
    function test_TakeRoutesFeesToTaker() public {
        // mimic sorts below ffffff → mimic is currency0, ffffff is currency1.
        // A zeroForOne=false swap spends currency1 (ffffff), so fees accrue on currency1.
        uint256 positionId = fountain.positionsCount();
        IERC20Metadata mimic = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");
        PoolKey memory key = _poolKeyOf(IERC20Metadata(address(mimic)));

        uint128 amountIn = 1e18;
        Trader alice = new Trader("alice", router);
        deal(ffffff, address(alice), uint256(amountIn));
        alice.swap(key, false, amountIn);

        uint256[] memory ids = new uint256[](1);
        ids[0] = positionId;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.untaken(ids);
        assertEq(pending0[0], 0, "no fees should accrue on currency0 (mimic)");
        assertGt(pending1[0], 0, "fees should accrue on currency1 (ffffff) after a buy");

        uint256 expected = pending1[0];
        uint256 takerBefore = IERC20Metadata(ffffff).balanceOf(address(bot));

        bot.take(positionId);

        assertEq(
            IERC20Metadata(ffffff).balanceOf(address(bot)) - takerBefore, expected, "TAKER received != untaken forecast"
        );

        (pending0, pending1) = fountain.untaken(ids);
        assertEq(pending0[0], 0, "residual currency0 fees after take");
        assertEq(pending1[0], 0, "residual currency1 fees after take");
    }

    /**
     * @notice Batch take sweeps several mimic positions in one unlock. Two
     *         mimics accrue fees on opposite currencies (ffffff as currency1
     *         vs zeros as currency0); a single {Fountain.take} pushes both
     *         forecasts to the taker.
     */
    function test_TakeBatchRoutesFeesToTaker() public {
        uint256 hiId = fountain.positionsCount();
        IERC20Metadata hiMimic = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");
        uint256 loId = fountain.positionsCount();
        IERC20Metadata loMimic = mimicoinage.mimic(Currency.wrap(zeros), "mimicZZ");

        PoolKey memory hiKey = _poolKeyOf(IERC20Metadata(address(hiMimic)));
        PoolKey memory loKey = _poolKeyOf(IERC20Metadata(address(loMimic)));

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
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.untaken(ids);
        assertGt(pending1[0], 0, "ffffff (currency1) fees should be pending on hi");
        assertGt(pending0[1], 0, "zeros (currency0) fees should be pending on lo");

        uint256 ffffffBefore = IERC20Metadata(ffffff).balanceOf(address(bot));
        uint256 zerosBefore = IERC20Metadata(zeros).balanceOf(address(bot));

        bot.takeBatch(ids);

        assertEq(
            IERC20Metadata(ffffff).balanceOf(address(bot)) - ffffffBefore,
            pending1[0],
            "bot ffffff delta != hi pending1"
        );
        assertEq(
            IERC20Metadata(zeros).balanceOf(address(bot)) - zerosBefore, pending0[1], "bot zeros delta != lo pending0"
        );

        (pending0, pending1) = fountain.untaken(ids);
        assertEq(pending0[0] + pending1[0] + pending0[1] + pending1[1], 0, "residual fees after batch take");
    }

    /**
     * @notice If the PoolKey was already initialized at the 1:1 genesis price
     *         (by someone else beating us to it benignly), {mimic} skips the
     *         re-init and completes normally.
     */
    function test_MimicIdempotentAtGenesisPrice() public {
        (, address predicted) = mimicoinage.predictMimic(Currency.wrap(ffffff), "mimicFF");
        PoolKey memory key = _predictedPoolKey(Currency.wrap(ffffff), "mimicFF");
        fountain.POOL_MANAGER().initialize(key, TickMath.getSqrtPriceAtTick(0));

        IERC20Metadata mimic = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");
        assertEq(address(mimic), predicted, "minted address != predicted");
        assertTrue(mimicoinage.isMimic(IERC20Metadata(address(mimic))), "mimic not registered");
    }

    /**
     * @notice Mimicoinage seats at `ticks[0] = 0`. A pre-init below user
     *         tick 0 is silently absorbed by Fountain — {mimic} succeeds,
     *         spot stays at the pre-init price, and the curve activates
     *         when buyers push spot up to 0. (No-flip orientation: mimic
     *         sorts below ffffff, so mimic = currency0 and "below user
     *         tick 0" matches "V4 tick < 0".)
     */
    function test_MimicAbsorbsPreInitBelowTicksZero() public {
        PoolKey memory key = _predictedPoolKey(Currency.wrap(ffffff), "mimicFF");
        uint160 preInitSqrt = TickMath.getSqrtPriceAtTick(-100);
        fountain.POOL_MANAGER().initialize(key, preInitSqrt);

        IERC20Metadata mimic = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");
        assertTrue(mimicoinage.isMimic(IERC20Metadata(address(mimic))), "mimic registered after below-tick pre-init");

        (uint160 sqrt,,,) = fountain.POOL_MANAGER().getSlot0(key.toId());
        assertEq(sqrt, preInitSqrt, "spot stays at pre-init price, not at ticks[0]=0");
    }

    /**
     * @notice A pre-init above user tick 0 leaves the first position
     *         spanning or below spot, so V4 demands the quote currency
     *         that Fountain doesn't settle. {mimic} reverts with V4's
     *         {IPoolManager.CurrencyNotSettled}. The mimic address is
     *         not registered. The workaround is to re-mint under a
     *         different `name` (different PoolKey) or walk the existing
     *         pool's spot back down to/below tick 0 first (free since
     *         the pool has no liquidity).
     */
    function test_MimicRevertsOnPreInitAboveTicksZero() public {
        PoolKey memory key = _predictedPoolKey(Currency.wrap(ffffff), "mimicFF");
        fountain.POOL_MANAGER().initialize(key, TickMath.getSqrtPriceAtTick(100));

        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF");

        // Re-minting under a different name yields a different PoolKey and succeeds.
        IERC20Metadata escaped = mimicoinage.mimic(Currency.wrap(ffffff), "mimicFF2");
        assertTrue(mimicoinage.isMimic(IERC20Metadata(address(escaped))), "rescue mint under new name failed");
    }

    /**
     * @dev Rebuild the {PoolKey} for a minted mimic — sorted against
     *      {Mimicoinage.originalOf} with this factory's fee/tickSpacing/hooks
     *      constants. The contract used to expose this directly; tests keep
     *      it local since off-chain callers can trivially reconstruct it.
     */
    function _poolKeyOf(IERC20Metadata mimic) internal view returns (PoolKey memory) {
        return _poolKey(address(mimic), mimicoinage.originalOf(mimic));
    }

    /**
     * @dev Rebuild the {PoolKey} {mimic} will compute for `(original, name)`
     *      using the predicted mimic CREATE2 address — lets a test pre-init
     *      the target pool before the mimic exists.
     */
    function _predictedPoolKey(Currency original, string memory name) internal view returns (PoolKey memory) {
        (, address predicted) = mimicoinage.predictMimic(original, name);
        return _poolKey(predicted, original);
    }

    function _poolKey(address mimic, Currency original) private view returns (PoolKey memory) {
        bool mimicIsToken0 = mimic < Currency.unwrap(original);
        return PoolKey({
            currency0: mimicIsToken0 ? Currency.wrap(mimic) : original,
            currency1: mimicIsToken0 ? original : Currency.wrap(mimic),
            fee: fountain.FEE(),
            tickSpacing: fountain.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
    }
}
