// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {Mimicry} from "../src/Mimicry.sol";
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
 *         fresh Mimicry prototype against the real PoolManagerLookup
 *         and Coinage factory, then exercises the two-level factory:
 *         per-(original, symbol) clones and per-name mimics minted from
 *         each clone. Fee take runs through {Fountain.take} directly —
 *         Mimicry clones only mint the mimic and seat its position;
 *         everything post-launch lives on the Fountain and PoolManager.
 *
 *         Tests use the convention `name == symbol` for the single
 *         in-test mint per clone.
 *
 *         Run with:
 *           forge test --match-contract MimicryForkTest -f mainnet -vv
 *         or pin a block for reproducibility:
 *           FORK_BLOCK=24923365 forge test --match-contract MimicryForkTest -f mainnet -vv
 */
contract MimicryForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    Fountain internal fountain;
    Mimicry internal mimicry;
    SwapRouter internal router;
    Funder internal bot;

    function setUp() public override {
        super.setUp();

        bot = new Funder("bot");
        Fountain proto = new Fountain(IAddressLookup(PoolManagerLookup));
        bot.makeFountain(proto);
        fountain = bot.fountain();
        mimicry = new Mimicry(fountain, Coinage(ICoinage));
        router = new SwapRouter(fountain.poolManager());
    }

    function test_MadeMatchesMake() public {
        Currency original = Currency.wrap(USDC);
        string memory symbol = "USDCx1";

        (bool cloneExistsBefore, address predictedClone,) = mimicry.made(original, symbol);
        (bool mimicExistsBefore, address predictedMimic) = mimicry.mimicked(original, symbol, symbol);
        assertFalse(cloneExistsBefore, "fresh Mimicry cannot have pre-existing clones");
        assertFalse(mimicExistsBefore, "fresh Mimicry cannot have pre-existing mimics");
        assertTrue(predictedClone != address(0), "predicted clone is zero");
        assertTrue(predictedMimic != address(0), "predicted mimic is zero");

        (Mimicry clone, IERC20Metadata mimic) = _makeAndMimic(original, symbol);
        assertEq(address(clone), predictedClone, "deployed clone differs from prediction");
        assertEq(address(mimic), predictedMimic, "minted mimic differs from prediction");

        (bool cloneExistsAfter,,) = mimicry.made(original, symbol);
        (bool mimicExistsAfter,) = mimicry.mimicked(original, symbol, symbol);
        assertTrue(cloneExistsAfter, "clone not registered as existing after make");
        assertTrue(mimicExistsAfter, "mimic not registered as existing after mimic()");
    }

    function test_MakeUSDC() public {
        (Mimicry clone, IERC20Metadata mimic) = _makeAndMimic(Currency.wrap(USDC), "USDCx1");

        assertEq(mimic.decimals(), IERC20Metadata(USDC).decimals(), "decimals must match original");
        assertEq(mimic.symbol(), "USDCx1", "symbol must round-trip through mimic");
        assertEq(Currency.unwrap(clone.original()), USDC, "clone.original must point at USDC");
        assertEq(clone.symbol(), "USDCx1", "clone.symbol must round-trip");

        // Pool is initialized at tick 0 (sqrtPriceX96 for tick 0 = 2**96).
        PoolId id = _poolKeyOf(clone, mimic).toId();
        (uint160 sqrtPriceX96, int24 tick,,) = fountain.poolManager().getSlot0(id);
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");

        // Entire supply is seated in the position — neither the clone nor the prototype holds any.
        assertEq(mimic.balanceOf(address(clone)), 0, "supply should be in V4, not in clone");
        assertEq(mimic.balanceOf(address(mimicry)), 0, "supply should be in V4, not in prototype");
    }

    /**
     * @notice The prototype is itself the canonical factory for the
     *         `(native ETH, "1xETH")` pair: `proto.mimic(name)` mints a
     *         1xETH-ETH mimic directly from the prototype, `make` for
     *         that pair returns proto without deploying a separate
     *         clone, and `made` reports the proto address with a zero
     *         salt.
     */
    function test_ProtoIsETHFactory() public {
        assertEq(mimicry.symbol(), "1xETH", "proto symbol");
        assertEq(Currency.unwrap(mimicry.original()), address(0), "proto original is native ETH");

        Currency native = Currency.wrap(address(0));
        (bool cloneExists, address cloneHome, bytes32 salt) = mimicry.made(native, "1xETH");
        assertTrue(cloneExists, "proto pair must report exists=true");
        assertEq(cloneHome, address(mimicry), "proto pair must map to proto address");
        assertEq(salt, bytes32(0), "proto pair must report zero salt");

        Mimicry self = mimicry.make(native, "1xETH");
        assertEq(address(self), address(mimicry), "make on proto pair must return proto");

        (bool mimicExistsBefore, address predictedMimic) = mimicry.mimicked(native, "1xETH", "alpha");
        assertFalse(mimicExistsBefore, "fresh proto cannot have pre-existing mimics");

        IERC20Metadata token = mimicry.mimic("alpha");
        assertEq(address(token), predictedMimic, "minted mimic differs from prediction");
        assertEq(token.symbol(), "1xETH", "minted symbol must round-trip");
        assertEq(token.decimals(), uint8(18), "native mimic must have 18 decimals");

        // Pool initialized at tick 0 with the entire supply seated single-sided.
        PoolKey memory key = _poolKeyOf(mimicry, token);
        (uint160 sqrtPriceX96, int24 tick,,) = fountain.poolManager().getSlot0(key.toId());
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertEq(token.balanceOf(address(mimicry)), 0, "supply should be in V4, not in proto");
    }

    /**
     * @notice Native ETH as the original: Mimicry falls back to 18
     *         decimals (no on-chain metadata to read), records the original
     *         on the clone, and seats the mimic in a Fountain position
     *         whose `currency0` is `address(0)`.
     */
    function test_MakeNativeETH() public {
        (Mimicry clone, IERC20Metadata mimic) = _makeAndMimic(Currency.wrap(address(0)), "ETHx1");

        assertEq(mimic.decimals(), uint8(18), "native mimic must have 18 decimals");
        assertEq(mimic.symbol(), "ETHx1", "native mimic symbol must round-trip");
        assertEq(Currency.unwrap(clone.original()), address(0), "clone.original must point to native ETH");

        // Mimic is a contract address (> 0), ETH sorts below: ETH = currency0, mimic = currency1.
        PoolKey memory key = _poolKeyOf(clone, mimic);
        assertEq(Currency.unwrap(key.currency0), address(0), "ETH is currency0");
        assertEq(Currency.unwrap(key.currency1), address(mimic), "mimic is currency1");

        // Pool initialized at tick 0; entire mimic supply seated in Fountain position.
        (uint160 sqrtPriceX96, int24 tick,,) = fountain.poolManager().getSlot0(key.toId());
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertEq(mimic.balanceOf(address(clone)), 0, "supply should be in V4, not in clone");
        assertEq(fountain.positionsCount(), 1, "mimic must seat exactly one Fountain position");
    }

    /**
     * @notice An ETH-pegged clone for a non-`"1xETH"` symbol that does
     *         not yet exist deploys via the normal clone path:
     *         `made` flips from false to true, `make` produces a clone
     *         at the predicted address with the requested symbol, and
     *         the minted mimic carries the clone's symbol rather than
     *         proto's `"1xETH"`.
     */
    function test_MakeNativeETHWithNonProtoSymbol() public {
        Currency native = Currency.wrap(address(0));
        string memory symbol = "ETHx1";

        (bool existsBefore, address predictedClone,) = mimicry.made(native, symbol);
        assertFalse(existsBefore, "fresh non-proto clone cannot pre-exist");
        assertTrue(predictedClone != address(0), "predicted clone is zero");

        (Mimicry clone, IERC20Metadata token) = _makeAndMimic(native, symbol);
        assertEq(address(clone), predictedClone, "deployed clone differs from prediction");
        assertEq(Currency.unwrap(clone.original()), address(0), "clone.original is native ETH");
        assertEq(clone.symbol(), symbol, "clone.symbol must round-trip");
        assertEq(token.symbol(), symbol, "minted mimic carries clone symbol");

        (bool existsAfter,,) = mimicry.made(native, symbol);
        assertTrue(existsAfter, "clone must register as existing after make");
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

        (Mimicry hiClone, IERC20Metadata hiMimic) = _makeAndMimic(Currency.wrap(ffffff), "FFx1");
        (Mimicry loClone, IERC20Metadata loMimic) = _makeAndMimic(Currency.wrap(zeros), "ZZx1");

        assertLt(uint160(address(hiMimic)), uint160(ffffff), "mimic of high lepton must sort below (token0)");
        assertGt(uint160(address(loMimic)), uint160(zeros), "mimic of low lepton must sort above (token1)");

        (uint160 hiSqrt, int24 hiTick,,) = fountain.poolManager().getSlot0(_poolKeyOf(hiClone, hiMimic).toId());
        (uint160 loSqrt, int24 loTick,,) = fountain.poolManager().getSlot0(_poolKeyOf(loClone, loMimic).toId());

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
        (Mimicry hiClone, IERC20Metadata hiMimic) = _makeAndMimic(Currency.wrap(ffffff), "FFx1");
        (Mimicry loClone, IERC20Metadata loMimic) = _makeAndMimic(Currency.wrap(zeros), "ZZx1");

        PoolKey memory hiKey = _poolKeyOf(hiClone, hiMimic);
        PoolKey memory loKey = _poolKeyOf(loClone, loMimic);

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
        (Mimicry hiClone, IERC20Metadata hiMimic) = _makeAndMimic(Currency.wrap(ffffff), "FFx1");
        (Mimicry loClone, IERC20Metadata loMimic) = _makeAndMimic(Currency.wrap(zeros), "ZZx1");

        PoolKey memory hiKey = _poolKeyOf(hiClone, hiMimic);
        PoolKey memory loKey = _poolKeyOf(loClone, loMimic);

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
        (Mimicry clone, IERC20Metadata mimic) = _makeAndMimic(Currency.wrap(ffffff), "FFx1");
        PoolKey memory key = _poolKeyOf(clone, mimic);

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
        (Mimicry hiClone, IERC20Metadata hiMimic) = _makeAndMimic(Currency.wrap(ffffff), "FFx1");
        uint256 loId = fountain.positionsCount();
        (Mimicry loClone, IERC20Metadata loMimic) = _makeAndMimic(Currency.wrap(zeros), "ZZx1");

        PoolKey memory hiKey = _poolKeyOf(hiClone, hiMimic);
        PoolKey memory loKey = _poolKeyOf(loClone, loMimic);

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
        Currency original = Currency.wrap(ffffff);
        string memory symbol = "FFx1";
        (, address predictedMimic) = mimicry.mimicked(original, symbol, symbol);
        PoolKey memory key = _predictedPoolKey(original, symbol, symbol);
        fountain.poolManager().initialize(key, TickMath.getSqrtPriceAtTick(0));

        (, IERC20Metadata mimic) = _makeAndMimic(original, symbol);
        assertEq(address(mimic), predictedMimic, "minted address != predicted");

        (bool exists,,) = mimicry.made(original, symbol);
        assertTrue(exists, "clone not deployed after make at pre-init genesis");
    }

    /**
     * @notice Mimicry seats at `ticks[0] = 0`. A pre-init below user
     *         tick 0 is silently absorbed by Fountain — {mimic} succeeds,
     *         spot stays at the pre-init price, and the curve activates
     *         when buyers push spot up to 0. (No-flip orientation: mimic
     *         sorts below ffffff, so mimic = currency0 and "below user
     *         tick 0" matches "V4 tick < 0".)
     */
    function test_MimicAbsorbsPreInitBelowTicksZero() public {
        Currency original = Currency.wrap(ffffff);
        string memory symbol = "FFx1";
        PoolKey memory key = _predictedPoolKey(original, symbol, symbol);
        uint160 preInitSqrt = TickMath.getSqrtPriceAtTick(-100);
        fountain.poolManager().initialize(key, preInitSqrt);

        (, IERC20Metadata mimic) = _makeAndMimic(original, symbol);
        assertTrue(address(mimic) != address(0), "mimic not minted after below-tick pre-init");

        (uint160 sqrt,,,) = fountain.poolManager().getSlot0(key.toId());
        assertEq(sqrt, preInitSqrt, "spot stays at pre-init price, not at ticks[0]=0");
    }

    /**
     * @notice A pre-init above user tick 0 leaves the first position
     *         spanning or below spot, so V4 demands the quote currency
     *         that Fountain doesn't settle. {mimic} reverts with V4's
     *         {IPoolManager.CurrencyNotSettled}; the clone itself is
     *         already deployed (cheap) and can mint another mimic under
     *         a different `name` to dodge the locked PoolKey.
     */
    function test_MimicRevertsOnPreInitAboveTicksZero() public {
        Currency original = Currency.wrap(ffffff);
        string memory symbol = "FFx1";
        PoolKey memory key = _predictedPoolKey(original, symbol, symbol);
        fountain.poolManager().initialize(key, TickMath.getSqrtPriceAtTick(100));

        Mimicry clone = mimicry.make(original, symbol);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        clone.mimic(symbol);

        // Re-mint under a different name yields a different mimic and PoolKey, succeeds.
        IERC20Metadata escapedMimic = clone.mimic("FFx1-escape");
        assertTrue(address(escapedMimic) != address(0), "rescue mimic under new name failed");
    }

    /**
     * @dev Make a clone for `(original, symbol)` and mint a single mimic
     *      under the convention `name == symbol`. Returns the (clone,
     *      token) pair tests need to recover the PoolKey.
     */
    function _makeAndMimic(Currency original, string memory symbol)
        internal
        returns (Mimicry clone, IERC20Metadata token)
    {
        clone = mimicry.make(original, symbol);
        token = clone.mimic(symbol);
    }

    /**
     * @dev Rebuild the {PoolKey} for a (clone, token) pair using this
     *      factory's fee/tickSpacing/hooks constants.
     */
    function _poolKeyOf(Mimicry clone, IERC20Metadata token) internal view returns (PoolKey memory) {
        return _poolKey(address(token), clone.original());
    }

    /**
     * @dev Rebuild the {PoolKey} that {mimic} will compute for `(original,
     *      symbol, name)` using the predicted mimic CREATE2 address — lets
     *      a test pre-init the target pool before the mimic is minted.
     */
    function _predictedPoolKey(Currency original, string memory symbol, string memory name)
        internal
        view
        returns (PoolKey memory)
    {
        (, address predictedMimic) = mimicry.mimicked(original, symbol, name);
        return _poolKey(predictedMimic, original);
    }

    function _poolKey(address mimic, Currency original) private view returns (PoolKey memory) {
        bool mimicIsToken0 = mimic < Currency.unwrap(original);
        return PoolKey({
            currency0: mimicIsToken0 ? Currency.wrap(mimic) : original,
            currency1: mimicIsToken0 ? original : Currency.wrap(mimic),
            fee: fountain.fee(),
            tickSpacing: fountain.tickSpacing(),
            hooks: IHooks(address(0))
        });
    }
}
