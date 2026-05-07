// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {Notable} from "../src/Notable.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {Funder} from "./Funder.sol";
import {SwapRouter} from "./SwapRouter.sol";
import {Trader} from "./Trader.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IStringLookup} from "ilookup/IStringLookup.sol";
import {ICoinage as Coinage} from "icoinage/ICoinage.sol";
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
 * @notice Fixed-string IStringLookup for fork tests — returns "ETH" so
 *         the prototype's symbol resolves to "1xETH" regardless of the
 *         forked chain.
 */
contract NativeSymbolStub is IStringLookup {
    function value() external pure returns (string memory) {
        return "ETH";
    }
}

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
 * @notice Fork test against `forknet` state. Deploys a fresh Fountain and a
 *         fresh Notable prototype against the real PoolManagerLookup
 *         and Coinage factory, then exercises the two-level factory:
 *         per-(original, symbol) clones and per-name issues minted from
 *         each clone. Fee take runs through {Fountain.take} directly —
 *         Notable clones only mint the issue and seat its position;
 *         everything post-launch lives on the Fountain and PoolManager.
 *
 *         Tests use the convention `name == symbol` for the single
 *         in-test mint per clone.
 *
 *         Run with:
 *           forge test --match-contract NotableForkTest -f forknet -vv
 *         or pin a block for reproducibility:
 *           FORK_BLOCK=458766451 forge test --match-contract NotableForkTest -f forknet -vv
 */
contract NotableForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    Fountain internal fountain;
    Notable internal notable;
    SwapRouter internal router;
    Funder internal bot;

    function setUp() public override {
        super.setUp();

        bot = new Funder("bot");
        Fountain proto = new Fountain(IAddressLookup(PoolManagerLookup));
        bot.makeFountain(proto);
        fountain = bot.fountain();
        notable = new Notable(fountain, Coinage(ICoinage), new NativeSymbolStub());
        router = new SwapRouter(IPoolManager(fountain.poolManager()));
    }

    function test_MadeMatchesMake() public {
        address original = USDC;
        string memory symbol = "USDCx1";

        (bool cloneExistsBefore, address predictedClone,) = notable.made(original, symbol);
        (bool issueExistsBefore, address predictedIssue) = notable.issued(original, symbol, symbol);
        assertFalse(cloneExistsBefore, "fresh Notable cannot have pre-existing clones");
        assertFalse(issueExistsBefore, "fresh Notable cannot have pre-existing issues");
        assertTrue(predictedClone != address(0), "predicted clone is zero");
        assertTrue(predictedIssue != address(0), "predicted issue is zero");

        (Notable clone, IERC20Metadata issue) = _makeAndIssue(original, symbol);
        assertEq(address(clone), predictedClone, "deployed clone differs from prediction");
        assertEq(address(issue), predictedIssue, "minted issue differs from prediction");

        (bool cloneExistsAfter,,) = notable.made(original, symbol);
        (bool issueExistsAfter,) = notable.issued(original, symbol, symbol);
        assertTrue(cloneExistsAfter, "clone not registered as existing after make");
        assertTrue(issueExistsAfter, "issue not registered as existing after issue()");
    }

    function test_MakeUSDC() public {
        (Notable clone, IERC20Metadata issue) = _makeAndIssue(USDC, "USDCx1");

        assertEq(issue.decimals(), IERC20Metadata(USDC).decimals(), "decimals must match original");
        assertEq(issue.symbol(), "USDCx1", "symbol must round-trip through issue");
        assertEq(clone.original(), USDC, "clone.original must point at USDC");
        assertEq(clone.symbol(), "USDCx1", "clone.symbol must round-trip");

        // Pool is initialized at tick 0 (sqrtPriceX96 for tick 0 = 2**96).
        PoolId id = _poolKeyOf(clone, issue).toId();
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(fountain.poolManager()).getSlot0(id);
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");

        // Entire supply is seated in the position — neither the clone nor the prototype holds any.
        assertEq(issue.balanceOf(address(clone)), 0, "supply should be in V4, not in clone");
        assertEq(issue.balanceOf(address(notable)), 0, "supply should be in V4, not in prototype");
    }

    /**
     * @notice The prototype is itself the canonical factory for the
     *         `(native ETH, "1xETH")` pair: `proto.issue(name)` mints a
     *         1xETH-ETH issue directly from the prototype, `make` for
     *         that pair returns proto without deploying a separate
     *         clone, and `made` reports the proto address with a zero
     *         salt.
     */
    function test_ProtoIsETHFactory() public {
        assertEq(notable.symbol(), "1xETH", "proto symbol");
        assertEq(notable.original(), address(0), "proto original is native ETH");

        address native = address(0);
        (bool cloneExists, address cloneHome, bytes32 salt) = notable.made(native, "1xETH");
        assertTrue(cloneExists, "proto pair must report exists=true");
        assertEq(cloneHome, address(notable), "proto pair must map to proto address");
        assertEq(salt, bytes32(0), "proto pair must report zero salt");

        Notable self = Notable(notable.make(native, "1xETH"));
        assertEq(address(self), address(notable), "make on proto pair must return proto");

        (bool issueExistsBefore, address predictedIssue) = notable.issued(native, "1xETH", "alpha");
        assertFalse(issueExistsBefore, "fresh proto cannot have pre-existing issues");

        IERC20Metadata token = notable.issue("alpha");
        assertEq(address(token), predictedIssue, "minted issue differs from prediction");
        assertEq(token.symbol(), "1xETH", "minted symbol must round-trip");
        assertEq(token.decimals(), uint8(18), "native issue must have 18 decimals");

        // Pool initialized at tick 0 with the entire supply seated single-sided.
        PoolKey memory key = _poolKeyOf(notable, token);
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(fountain.poolManager()).getSlot0(key.toId());
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertEq(token.balanceOf(address(notable)), 0, "supply should be in V4, not in proto");
    }

    /**
     * @notice Native ETH as the original: Notable falls back to 18
     *         decimals (no on-chain metadata to read), records the original
     *         on the clone, and seats the issue in a Fountain position
     *         whose `currency0` is `address(0)`.
     */
    function test_MakeNativeETH() public {
        (Notable clone, IERC20Metadata issue) = _makeAndIssue(address(0), "ETHx1");

        assertEq(issue.decimals(), uint8(18), "native issue must have 18 decimals");
        assertEq(issue.symbol(), "ETHx1", "native issue symbol must round-trip");
        assertEq(clone.original(), address(0), "clone.original must point to native ETH");

        // Issue is a contract address (> 0), ETH sorts below: ETH = currency0, issue = currency1.
        PoolKey memory key = _poolKeyOf(clone, issue);
        assertEq(Currency.unwrap(key.currency0), address(0), "ETH is currency0");
        assertEq(Currency.unwrap(key.currency1), address(issue), "issue is currency1");

        // Pool initialized at tick 0; entire issue supply seated in Fountain position.
        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(fountain.poolManager()).getSlot0(key.toId());
        assertEq(tick, int24(0), "pool must initialize at tick 0");
        assertGt(sqrtPriceX96, 0, "pool not initialized");
        assertEq(issue.balanceOf(address(clone)), 0, "supply should be in V4, not in clone");
        assertEq(fountain.positionsCount(), 1, "issue must seat exactly one Fountain position");
    }

    /**
     * @notice An ETH-pegged clone for a non-`"1xETH"` symbol that does
     *         not yet exist deploys via the normal clone path:
     *         `made` flips from false to true, `make` produces a clone
     *         at the predicted address with the requested symbol, and
     *         the minted issue carries the clone's symbol rather than
     *         proto's `"1xETH"`.
     */
    function test_MakeNativeETHWithNonProtoSymbol() public {
        address native = address(0);
        string memory symbol = "ETHx1";

        (bool existsBefore, address predictedClone,) = notable.made(native, symbol);
        assertFalse(existsBefore, "fresh non-proto clone cannot pre-exist");
        assertTrue(predictedClone != address(0), "predicted clone is zero");

        (Notable clone, IERC20Metadata token) = _makeAndIssue(native, symbol);
        assertEq(address(clone), predictedClone, "deployed clone differs from prediction");
        assertEq(clone.original(), address(0), "clone.original is native ETH");
        assertEq(clone.symbol(), symbol, "clone.symbol must round-trip");
        assertEq(token.symbol(), symbol, "minted issue carries clone symbol");

        (bool existsAfter,,) = notable.made(native, symbol);
        assertTrue(existsAfter, "clone must register as existing after make");
    }

    /**
     * @notice Both orderings must initialize at the identical 1:1 spot price.
     *         `ffffff` is a high-address lepton (issue sorts below → token0);
     *         `zeros` is a low-address lepton (issue sorts above → token1).
     *         Sanity checks the ordering, then asserts both pools land at
     *         tick 0 with sqrtPriceX96 = 2**96.
     */
    function test_BothOrderingsIssueAtIdenticalPrice() public {
        require(ffffff.code.length > 0, "ffffff lepton missing at forked block");
        require(zeros.code.length > 0, "zeros lepton missing at forked block");

        (Notable hiClone, IERC20Metadata hiIssue) = _makeAndIssue(ffffff, "FFx1");
        (Notable loClone, IERC20Metadata loIssue) = _makeAndIssue(zeros, "ZZx1");

        assertLt(uint160(address(hiIssue)), uint160(ffffff), "issue of high lepton must sort below (token0)");
        assertGt(uint160(address(loIssue)), uint160(zeros), "issue of low lepton must sort above (token1)");

        (uint160 hiSqrt, int24 hiTick,,) =
            IPoolManager(fountain.poolManager()).getSlot0(_poolKeyOf(hiClone, hiIssue).toId());
        (uint160 loSqrt, int24 loTick,,) =
            IPoolManager(fountain.poolManager()).getSlot0(_poolKeyOf(loClone, loIssue).toId());

        assertEq(hiTick, int24(0), "high-lepton pool must initialize at tick 0");
        assertEq(loTick, int24(0), "low-lepton pool must initialize at tick 0");
        assertEq(uint256(hiSqrt), FixedPoint96.Q96, "high-lepton pool sqrtPrice != 2**96");
        assertEq(uint256(loSqrt), FixedPoint96.Q96, "low-lepton pool sqrtPrice != 2**96");
        assertEq(hiSqrt, loSqrt, "spot prices must match across orderings");
    }

    /**
     * @notice Equivalent swaps across the two orderings must quote the same
     *         output. Buys `issue` with `original` in each pool; the range
     *         geometry differs (issue-above vs issue-below) but the fee tier,
     *         tick spacing, and seated supply are identical, so outputs
     *         should match to sub-bp precision.
     */
    function test_QuotedOutputsMatchAcrossOrdering() public {
        (Notable hiClone, IERC20Metadata hiIssue) = _makeAndIssue(ffffff, "FFx1");
        (Notable loClone, IERC20Metadata loIssue) = _makeAndIssue(zeros, "ZZx1");

        PoolKey memory hiKey = _poolKeyOf(hiClone, hiIssue);
        PoolKey memory loKey = _poolKeyOf(loClone, loIssue);

        // Buy issue with original:
        //   hi pool — issue is token0, original is token1 → oneForZero (zeroForOne=false)
        //   lo pool — issue is token1, original is token0 → zeroForOne=true
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
        (Notable hiClone, IERC20Metadata hiIssue) = _makeAndIssue(ffffff, "FFx1");
        (Notable loClone, IERC20Metadata loIssue) = _makeAndIssue(zeros, "ZZx1");

        PoolKey memory hiKey = _poolKeyOf(hiClone, hiIssue);
        PoolKey memory loKey = _poolKeyOf(loClone, loIssue);

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

        // Sanity: price moved after the first buy, so the second buy gets less issue.
        assertLt(hi2, hi1, "hi: second buy did not reflect advanced pool state");
        assertLt(lo2, lo1, "lo: second buy did not reflect advanced pool state");
    }

    /**
     * @notice A swap accrues fees on the input side of the position; Fountain
     *         routes them to its taker (the bot) on {take}. Verifies both
     *         the {Fountain.untaken} forecast and the actual transfer.
     */
    function test_TakeRoutesFeesToTaker() public {
        // issue sorts below ffffff → issue is currency0, ffffff is currency1.
        // A zeroForOne=false swap spends currency1 (ffffff), so fees accrue on currency1.
        uint256 positionId = fountain.positionsCount();
        (Notable clone, IERC20Metadata issue) = _makeAndIssue(ffffff, "FFx1");
        PoolKey memory key = _poolKeyOf(clone, issue);

        uint128 amountIn = 1e18;
        Trader alice = new Trader("alice", router);
        deal(ffffff, address(alice), uint256(amountIn));
        alice.swap(key, false, amountIn);

        uint256[] memory ids = new uint256[](1);
        ids[0] = positionId;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.untaken(ids);
        assertEq(pending0[0], 0, "no fees should accrue on currency0 (issue)");
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
     * @notice Batch take sweeps several issue positions in one unlock. Two
     *         issues accrue fees on opposite currencies (ffffff as currency1
     *         vs zeros as currency0); a single {Fountain.take} pushes both
     *         forecasts to the taker.
     */
    function test_TakeBatchRoutesFeesToTaker() public {
        uint256 hiId = fountain.positionsCount();
        (Notable hiClone, IERC20Metadata hiIssue) = _makeAndIssue(ffffff, "FFx1");
        uint256 loId = fountain.positionsCount();
        (Notable loClone, IERC20Metadata loIssue) = _makeAndIssue(zeros, "ZZx1");

        PoolKey memory hiKey = _poolKeyOf(hiClone, hiIssue);
        PoolKey memory loKey = _poolKeyOf(loClone, loIssue);

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
     *         (by someone else beating us to it benignly), {issue} skips the
     *         re-init and completes normally.
     */
    function test_IssueIdempotentAtGenesisPrice() public {
        address original = ffffff;
        string memory symbol = "FFx1";
        (, address predictedIssue) = notable.issued(original, symbol, symbol);
        PoolKey memory key = _predictedPoolKey(original, symbol, symbol);
        IPoolManager(fountain.poolManager()).initialize(key, TickMath.getSqrtPriceAtTick(0));

        (, IERC20Metadata issue) = _makeAndIssue(original, symbol);
        assertEq(address(issue), predictedIssue, "minted address != predicted");

        (bool exists,,) = notable.made(original, symbol);
        assertTrue(exists, "clone not deployed after make at pre-init genesis");
    }

    /**
     * @notice Notable seats at `ticks[0] = 0`. A pre-init below user
     *         tick 0 is silently absorbed by Fountain — {issue} succeeds,
     *         spot stays at the pre-init price, and the curve activates
     *         when buyers push spot up to 0. (No-flip orientation: issue
     *         sorts below ffffff, so issue = currency0 and "below user
     *         tick 0" matches "V4 tick < 0".)
     */
    function test_IssueAbsorbsPreInitBelowTicksZero() public {
        address original = ffffff;
        string memory symbol = "FFx1";
        PoolKey memory key = _predictedPoolKey(original, symbol, symbol);
        uint160 preInitSqrt = TickMath.getSqrtPriceAtTick(-100);
        IPoolManager(fountain.poolManager()).initialize(key, preInitSqrt);

        (, IERC20Metadata issue) = _makeAndIssue(original, symbol);
        assertTrue(address(issue) != address(0), "issue not minted after below-tick pre-init");

        (uint160 sqrt,,,) = IPoolManager(fountain.poolManager()).getSlot0(key.toId());
        assertEq(sqrt, preInitSqrt, "spot stays at pre-init price, not at ticks[0]=0");
    }

    /**
     * @notice A pre-init above user tick 0 leaves the first position
     *         spanning or below spot, so V4 demands the quote currency
     *         that Fountain doesn't settle. {issue} reverts with V4's
     *         {IPoolManager.CurrencyNotSettled}; the clone itself is
     *         already deployed (cheap) and can mint another issue under
     *         a different `name` to dodge the locked PoolKey.
     */
    function test_IssueRevertsOnPreInitAboveTicksZero() public {
        address original = ffffff;
        string memory symbol = "FFx1";
        PoolKey memory key = _predictedPoolKey(original, symbol, symbol);
        IPoolManager(fountain.poolManager()).initialize(key, TickMath.getSqrtPriceAtTick(100));

        Notable clone = Notable(notable.make(original, symbol));
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        clone.issue(symbol);

        // Re-mint under a different name yields a different issue and PoolKey, succeeds.
        IERC20Metadata escapedIssue = clone.issue("FFx1-escape");
        assertTrue(address(escapedIssue) != address(0), "rescue issue under new name failed");
    }

    /**
     * @dev Make a clone for `(original, symbol)` and mint a single issue
     *      under the convention `name == symbol`. Returns the (clone,
     *      token) pair tests need to recover the PoolKey.
     */
    function _makeAndIssue(address original, string memory symbol)
        internal
        returns (Notable clone, IERC20Metadata token)
    {
        clone = Notable(notable.make(original, symbol));
        token = clone.issue(symbol);
    }

    /**
     * @dev Rebuild the {PoolKey} for a (clone, token) pair using this
     *      factory's fee/tickSpacing/hooks constants.
     */
    function _poolKeyOf(Notable clone, IERC20Metadata token) internal view returns (PoolKey memory) {
        return _poolKey(address(token), clone.original());
    }

    /**
     * @dev Rebuild the {PoolKey} that {issue} will compute for `(original,
     *      symbol, name)` using the predicted issue CREATE2 address — lets
     *      a test pre-init the target pool before the issue is minted.
     */
    function _predictedPoolKey(address original, string memory symbol, string memory name)
        internal
        view
        returns (PoolKey memory)
    {
        (, address predictedIssue) = notable.issued(original, symbol, name);
        return _poolKey(predictedIssue, original);
    }

    function _poolKey(address issue, address original) private view returns (PoolKey memory) {
        bool issueIsToken0 = issue < original;
        return PoolKey({
            currency0: Currency.wrap(issueIsToken0 ? issue : original),
            currency1: Currency.wrap(issueIsToken0 ? original : issue),
            fee: fountain.fee(),
            tickSpacing: fountain.tickSpacing(),
            hooks: IHooks(address(0))
        });
    }
}
