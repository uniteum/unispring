// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {IFountain} from "../src/IFountain.sol";
import {IFountainTaker, Position} from "../src/IFountainTaker.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {Funder} from "./Funder.sol";
import {SwapRouter} from "./SwapRouter.sol";
import {TestToken} from "./TestToken.sol";
import {Trader} from "./Trader.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @notice Fork test against mainnet state. Deploys a fresh Fountain against
 *         the real PoolManager resolved through the Uniteum
 *         `PoolManagerLookup`, then exercises offering, pre-initialization
 *         guards, validation, the position registry, fee accrual, and
 *         take across both tick-flip orientations and a native-ETH
 *         quote.
 *
 *         The {TestToken} deployed in setUp sits between the `zeros` (low)
 *         and `ffffff` (high) leptons defined by {ForkBase}, so pairing it
 *         against `ffffff` exercises the flip case (token sorts as
 *         `currency0`) and pairing it against `zeros` (or native ETH)
 *         exercises the no-flip case (token sorts as `currency1`).
 *
 *         Run with:
 *           forge test --match-contract FountainForkTest -f mainnet -vv
 *         or pin a block:
 *           FORK_BLOCK=24923365 forge test --match-contract FountainForkTest -f mainnet -vv
 */
contract FountainForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    Fountain internal fountain;
    SwapRouter internal router;
    Funder internal bot;
    TestToken internal token;

    uint256 internal constant SEGMENT_AMOUNT = 1_000_000 ether;
    // forge-lint: disable-next-line(screaming-snake-case-const)
    int24 internal constant tickSpacing = 1;

    function setUp() public override {
        super.setUp();

        bot = new Funder("bot");
        Fountain proto = new Fountain(IAddressLookup(PoolManagerLookup));
        bot.makeFountain(proto);
        fountain = bot.fountain();
        router = new SwapRouter(fountain.poolManager());
        token = _makeToken("MockToken", "MOCK", 18);

        require(ffffff.code.length > 0, "ffffff lepton missing at forked block");
        require(zeros.code.length > 0, "zeros lepton missing at forked block");
    }

    // ----------------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------------

    function test_ConstructorRegistersImmutables() public view {
        assertEq(fountain.owner(), address(bot), "owner set at make");
        assertGt(address(fountain.poolManager()).code.length, 0, "poolManager resolves to live code");
        assertEq(fountain.fee(), uint24(100), "fee constant");
    }

    // ----------------------------------------------------------------------
    // Offer — happy path (flip + no-flip + native ETH)
    // ----------------------------------------------------------------------

    function test_OfferSingleSegment_NoFlipCase() public {
        // token < ffffff → token is currency0, no flip; V4 ticks = user ticks.
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);

        assertEq(fountain.positionsCount(), 1, "one position created");

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), address(token), "token is currency0");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "ffffff is currency1");
        assertEq(p.tickLower, 100, "tickLower = ticks[0]");
        assertEq(p.tickUpper, 500, "tickUpper = ticks[1]");

        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(100), "starting price = ticks[0]");
    }

    function test_OfferSingleSegment_FlipCase() public {
        // token > zeros → token is currency1, flip: V4 = [-ticks[1], -ticks[0]).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(zeros), ticks, amounts);

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), zeros, "zeros is currency0");
        assertEq(Currency.unwrap(p.key.currency1), address(token), "token is currency1");
        assertEq(p.tickLower, -500, "tickLower = -ticks[1]");
        assertEq(p.tickUpper, -100, "tickUpper = -ticks[0]");

        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-100), "starting price = -ticks[0]");
    }

    function test_OfferSingleSegment_NativeETH() public {
        // ETH = address(0) → token > quote, flip: V4 = [-ticks[1], -ticks[0]).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(address(0)), ticks, amounts);

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), address(0), "ETH is currency0");
        assertEq(Currency.unwrap(p.key.currency1), address(token), "token is currency1");
        assertEq(p.tickLower, -500);
        assertEq(p.tickUpper, -100);

        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-100), "starting price = -ticks[0]");
    }

    function test_OfferSingleSegment_NativeETHAsToken() public {
        // token = ETH (address 0) → token < quote, no flip: V4 = [ticks[0], ticks[1]).
        // Caller sends `total` as msg.value; Fountain settles via settle{value:}.
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        vm.deal(address(this), SEGMENT_AMOUNT);
        uint256 pmBefore = address(fountain.poolManager()).balance;

        bot.offer{value: SEGMENT_AMOUNT}(Currency.wrap(address(0)), Currency.wrap(ffffff), ticks, amounts);

        assertEq(fountain.positionsCount(), 1, "one position created");

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), address(0), "ETH is currency0");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "ffffff is currency1");
        assertEq(p.tickLower, 100, "tickLower = ticks[0]");
        assertEq(p.tickUpper, 500, "tickUpper = ticks[1]");

        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(100), "starting price = ticks[0]");

        // ETH supply landed in PoolManager (modulo dust in Fountain).
        uint256 pmDelta = address(fountain.poolManager()).balance - pmBefore;
        uint256 inFountain = address(fountain).balance;
        assertEq(pmDelta + inFountain, SEGMENT_AMOUNT, "ETH conserved");
        assertGt(pmDelta, (SEGMENT_AMOUNT * 999) / 1000, "most ETH in PoolManager");
    }

    function test_OfferMultiSegment_NoFlipCase() public {
        // token < ffffff → no flip; V4 ranges = user ranges.
        int24[] memory ticks = new int24[](4);
        ticks[0] = 100;
        ticks[1] = 200;
        ticks[2] = 400;
        ticks[3] = 800;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        amounts[2] = 3e18;
        uint256 total = 6e18;
        _mint(total);

        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
        assertEq(fountain.positionsCount(), 3, "three positions");

        Position memory p0 = _positionAt(0);
        assertEq(p0.tickLower, 100);
        assertEq(p0.tickUpper, 200);
        Position memory p1 = _positionAt(1);
        assertEq(p1.tickLower, 200);
        assertEq(p1.tickUpper, 400);
        Position memory p2 = _positionAt(2);
        assertEq(p2.tickLower, 400);
        assertEq(p2.tickUpper, 800);

        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p0.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(100), "pool init at ticks[0]");

        // Token supply landed in PoolManager (modulo dust in Fountain).
        uint256 inPoolManager = IERC20(address(token)).balanceOf(address(fountain.poolManager()));
        uint256 inFountain = IERC20(address(token)).balanceOf(address(fountain));
        assertEq(inPoolManager + inFountain, total, "supply conserved");
        assertGt(inPoolManager, (total * 999) / 1000, "most supply in PoolManager");
    }

    function test_OfferMultiSegment_FlipCase() public {
        // token > zeros → flip; V4 range [-ticks[i+1], -ticks[i]).
        int24[] memory ticks = new int24[](4);
        ticks[0] = 100;
        ticks[1] = 200;
        ticks[2] = 400;
        ticks[3] = 800;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        amounts[2] = 3e18;
        _mint(6e18);

        bot.offer(Currency.wrap(address(token)), Currency.wrap(zeros), ticks, amounts);
        assertEq(fountain.positionsCount(), 3);

        Position memory p0 = _positionAt(0);
        assertEq(p0.tickLower, -200);
        assertEq(p0.tickUpper, -100);
        Position memory p1 = _positionAt(1);
        assertEq(p1.tickLower, -400);
        assertEq(p1.tickUpper, -200);
        Position memory p2 = _positionAt(2);
        assertEq(p2.tickLower, -800);
        assertEq(p2.tickUpper, -400);

        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p0.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-100), "pool init at -ticks[0]");
    }

    // ----------------------------------------------------------------------
    // Pool initialization guard
    // ----------------------------------------------------------------------

    function test_OfferIdempotentWhenPreInitAtCorrectPrice() public {
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        PoolKey memory key = _keyFor(ffffff);
        // No-flip case (token < ffffff): starting V4 tick = ticks[0] = 100.
        fountain.poolManager().initialize(key, TickMath.getSqrtPriceAtTick(100));

        _mint(SEGMENT_AMOUNT);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
        assertEq(fountain.positionsCount(), 1, "offer succeeded after matching pre-init");
    }

    /**
     * @notice Pre-init below `ticks[0]` is silently absorbed: positions
     *         seat above spot single-sided in token, the pool keeps its
     *         pre-init price, and the bonding curve activates as buyers
     *         push spot up into the user's range. No-flip case
     *         (token < ffffff): user `ticks[0]=100` → V4 start tick 100;
     *         pre-init at V4 tick 50 is below.
     */
    function test_OfferAbsorbsPreInitBelowTicksZero() public {
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        PoolKey memory key = _keyFor(ffffff);
        uint160 preInitSqrt = TickMath.getSqrtPriceAtTick(50);
        fountain.poolManager().initialize(key, preInitSqrt);

        _mint(SEGMENT_AMOUNT);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);

        assertEq(fountain.positionsCount(), 1, "position seated despite pre-init");
        (uint160 sqrt,,,) = fountain.poolManager().getSlot0(key.toId());
        assertEq(sqrt, preInitSqrt, "spot stays at pre-init price, not ticks[0]");

        uint256 inPoolManager = IERC20(address(token)).balanceOf(address(fountain.poolManager()));
        uint256 inFountain = IERC20(address(token)).balanceOf(address(fountain));
        assertEq(inPoolManager + inFountain, SEGMENT_AMOUNT, "supply conserved");
        assertGt(inPoolManager, (SEGMENT_AMOUNT * 999) / 1000, "supply seated single-sided in token");
    }

    /**
     * @notice Pre-init above `ticks[0]` reverts with V4's
     *         {IPoolManager.CurrencyNotSettled}: the first position spans
     *         or sits below spot, V4 demands the quote currency, Fountain
     *         only settles token. The legitimate offerer's funds are
     *         safe (transferFrom unwinds with the revert) but the error
     *         is opaque — no Fountain-named error names the pre-init
     *         price. Recovery: walk the price down externally with a
     *         1-wei swap (pool is empty), then re-call {offer}.
     */
    function test_OfferRevertsWhenPreInitAboveTicksZero() public {
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        PoolKey memory key = _keyFor(ffffff);
        fountain.poolManager().initialize(key, TickMath.getSqrtPriceAtTick(777));

        _mint(SEGMENT_AMOUNT);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    // ----------------------------------------------------------------------
    // Offer — validation errors
    // ----------------------------------------------------------------------

    function test_OfferRevertsOnNoPositions() public {
        int24[] memory ticks = new int24[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.expectRevert(IFountain.NoPositions.selector);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    function test_OfferRevertsOnLengthMismatch() public {
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.expectRevert(abi.encodeWithSelector(IFountain.TickAmountLengthMismatch.selector, uint256(2), uint256(2)));
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    function test_OfferRevertsOnTickOutOfRange() public {
        int24[] memory ticks = new int24[](2);
        ticks[0] = 100;
        ticks[1] = TickMath.MAX_TICK + 1;
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(IFountain.TickOutOfRange.selector, TickMath.MAX_TICK + 1));
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    function test_OfferRevertsOnTicksNotAscending() public {
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 300;
        ticks[2] = 200;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(IFountain.TicksNotAscending.selector, uint256(2), int24(300), int24(200))
        );
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    function test_OfferRevertsOnTicksEqual() public {
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 100;
        ticks[2] = 200;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.expectRevert(
            abi.encodeWithSelector(IFountain.TicksNotAscending.selector, uint256(1), int24(100), int24(100))
        );
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    function test_OfferRevertsOnZeroAmount() public {
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 200;
        ticks[2] = 300;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(IFountain.ZeroAmount.selector, uint256(1)));
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    function test_OfferRevertsWhenNativeTokenMsgValueMismatches() public {
        // token = native, msg.value short of `total` by 1 wei.
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        vm.deal(address(this), SEGMENT_AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(IFountain.NativeValueMismatch.selector, SEGMENT_AMOUNT, SEGMENT_AMOUNT - 1)
        );
        bot.offer{value: SEGMENT_AMOUNT - 1}(Currency.wrap(address(0)), Currency.wrap(ffffff), ticks, amounts);
    }

    function test_OfferRevertsWhenERC20TokenSentNativeValue() public {
        // token = ERC-20, msg.value must be zero.
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        vm.deal(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(IFountain.NativeValueMismatch.selector, uint256(0), uint256(1)));
        bot.offer{value: 1}(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    // ----------------------------------------------------------------------
    // Position registry views
    // ----------------------------------------------------------------------

    function test_MultipleOffersAppendToRegistry() public {
        _offerTwoFlip();
        assertEq(fountain.positionsCount(), 2, "first batch seated two positions");
        _offerTwoNoFlip();
        assertEq(fountain.positionsCount(), 4, "second batch appended after first");
    }

    function test_PositionsSliceClampBranches() public {
        _offerTwoFlip();
        _offerTwoNoFlip();
        assertEq(fountain.positionsCount(), 4);

        // Full slice.
        Position[] memory all = fountain.positionsSlice(0, 4);
        assertEq(all.length, 4, "full slice length");

        // Tail clamp: count runs past the end.
        Position[] memory tail = fountain.positionsSlice(2, 10);
        assertEq(tail.length, 2, "tail clamp length");

        // Offset at end and past end → empty.
        assertEq(fountain.positionsSlice(4, 5).length, 0, "offset == length empty");
        assertEq(fountain.positionsSlice(10, 5).length, 0, "offset past length empty");

        // Zero count → empty.
        assertEq(fountain.positionsSlice(0, 0).length, 0, "count == 0 empty");

        // Middle single element.
        Position[] memory mid = fountain.positionsSlice(1, 1);
        assertEq(mid.length, 1, "middle single-element length");
    }

    // ----------------------------------------------------------------------
    // Pending fees + take
    // ----------------------------------------------------------------------

    function test_UntakenZeroBeforeSwap() public {
        _offerTwoFlip();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        (uint256[] memory p0, uint256[] memory p1) = fountain.untaken(ids);
        assertEq(p0[0] + p1[0] + p0[1] + p1[1], 0, "no fees accrued before swaps");
    }

    function test_UntakenRevertsOnUnknownPosition() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 99;
        vm.expectRevert(abi.encodeWithSelector(IFountainTaker.UnknownPosition.selector, uint256(99)));
        fountain.untaken(ids);
    }

    function test_TakeSinglePosition_NoFlipCase() public {
        // token < ffffff (no flip): token=currency0. Buyer spends currency1
        // (ffffff) to receive currency0 (token) → zeroForOne=false.
        // Fees accrue on currency1 (ffffff).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);

        PoolKey memory key = _keyFor(ffffff);
        Trader alice = new Trader("alice", router);
        uint128 amountIn = 1e15;
        deal(ffffff, address(alice), uint256(amountIn));
        alice.swap(key, false, amountIn);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.untaken(ids);
        assertEq(pending0[0], 0, "no fees on currency0 (token)");
        assertGt(pending1[0], 0, "fees accrued on currency1 (ffffff)");

        uint256 expected = pending1[0];
        uint256 before = IERC20(ffffff).balanceOf(address(bot));
        bot.take(0);
        assertEq(IERC20(ffffff).balanceOf(address(bot)) - before, expected, "TAKER received untaken[1]");

        (pending0, pending1) = fountain.untaken(ids);
        assertEq(pending0[0] + pending1[0], 0, "residual fees after take");
    }

    function test_TakeSinglePosition_FlipCase() public {
        // token > zeros (flip): token=currency1. Buyer spends currency0
        // (zeros) to receive currency1 (token) → zeroForOne=true. Fees
        // accrue on currency0 (zeros).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(zeros), ticks, amounts);

        PoolKey memory key = _keyFor(zeros);
        Trader bobby = new Trader("bobby", router);
        uint128 amountIn = 1e15;
        deal(zeros, address(bobby), uint256(amountIn));
        bobby.swap(key, true, amountIn);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.untaken(ids);
        assertGt(pending0[0], 0, "fees accrued on currency0 (zeros)");
        assertEq(pending1[0], 0, "no fees on currency1 (token)");

        uint256 expected = pending0[0];
        uint256 before = IERC20(zeros).balanceOf(address(bot));
        bot.take(0);
        assertEq(IERC20(zeros).balanceOf(address(bot)) - before, expected, "TAKER received untaken[0]");
    }

    function test_TakeBatchAcrossTwoPools() public {
        // Batch takes across a flip-case pool (zeros quote) and a no-flip
        // pool (ffffff quote) in one unlock.
        _offerTwoFlip(); // ids 0, 1 against zeros
        _offerTwoNoFlip(); // ids 2, 3 against ffffff

        PoolKey memory flipKey = _keyFor(zeros);
        PoolKey memory noFlipKey = _keyFor(ffffff);

        Trader alice = new Trader("alice", router);
        Trader bobby = new Trader("bobby", router);
        deal(zeros, address(alice), 1e15);
        deal(ffffff, address(bobby), 1e15);
        // Flip pool: spend currency0 (zeros) to receive currency1 (token).
        alice.swap(flipKey, true, 1e15);
        // No-flip pool: spend currency1 (ffffff) to receive currency0 (token).
        bobby.swap(noFlipKey, false, 1e15);

        uint256[] memory ids = new uint256[](4);
        ids[0] = 0;
        ids[1] = 1;
        ids[2] = 2;
        ids[3] = 3;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.untaken(ids);
        // Flip pool fees on currency0 (zeros), no-flip pool fees on currency1 (ffffff).
        uint256 expectedZeros = pending0[0] + pending0[1];
        uint256 expectedFfffff = pending1[2] + pending1[3];
        assertGt(expectedZeros, 0, "flip case accrued zeros fees");
        assertGt(expectedFfffff, 0, "no-flip case accrued ffffff fees");

        uint256 ffffffBefore = IERC20(ffffff).balanceOf(address(bot));
        uint256 zerosBefore = IERC20(zeros).balanceOf(address(bot));
        bot.takeBatch(ids);

        assertEq(
            IERC20(ffffff).balanceOf(address(bot)) - ffffffBefore,
            expectedFfffff,
            "bot ffffff delta matches no-flip-case pending1 total"
        );
        assertEq(
            IERC20(zeros).balanceOf(address(bot)) - zerosBefore,
            expectedZeros,
            "bot zeros delta matches flip-case pending0 total"
        );

        (pending0, pending1) = fountain.untaken(ids);
        uint256 residual;
        for (uint256 i = 0; i < 4; i++) {
            residual += pending0[i] + pending1[i];
        }
        assertEq(residual, 0, "no residual fees after batch take");
    }

    function test_TakeRevertsOnUnknownPosition() public {
        vm.expectRevert(abi.encodeWithSelector(IFountainTaker.UnknownPosition.selector, uint256(99)));
        bot.take(99);
    }

    function test_TakeBatchRevertsIfAnyIdUnknown() public {
        _offerTwoFlip();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 0;
        ids[1] = 99;
        ids[2] = 1;
        vm.expectRevert(abi.encodeWithSelector(IFountainTaker.UnknownPosition.selector, uint256(99)));
        bot.takeBatch(ids);
    }

    function test_EmptyTakeBatchIsNoop() public {
        vm.recordLogs();
        bot.takeBatch(new uint256[](0));
        assertEq(vm.getRecordedLogs().length, 0, "empty takeBatch emits nothing");
    }

    // ----------------------------------------------------------------------
    // Bonding-curve behavior across segments
    // ----------------------------------------------------------------------

    /**
     * @notice A single buy large enough to consume part of the curve should
     *         leave the pool's tick strictly inside the next segment's range
     *         — verifying that multi-segment curves are contiguous and
     *         consumed in the expected order (flip case: token > quote).
     */
    function test_MultiSegmentFlipCurveConsumesInOrder() public {
        int24[] memory ticks = new int24[](4);
        ticks[0] = 100;
        ticks[1] = 200;
        ticks[2] = 400;
        ticks[3] = 800;
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        amounts[2] = 1e18;
        _mint(3e18);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(zeros), ticks, amounts);
        PoolKey memory key = _keyFor(zeros);

        // Starting V4 tick is -100 (top of position 0 at V4 [-200, -100)).
        // Buyer spending zeros (currency0) for token (currency1) drives the
        // V4 tick downward through positions 0, 1, 2 in order.
        (, int24 tickBefore,,) = fountain.poolManager().getSlot0(key.toId());
        assertEq(tickBefore, int24(-100), "starts at -ticks[0]");

        Trader alice = new Trader("alice", router);
        uint128 amountIn = 1e18;
        deal(zeros, address(alice), uint256(amountIn));
        alice.swap(key, true, amountIn);

        (, int24 tickAfter,,) = fountain.poolManager().getSlot0(key.toId());
        assertLt(tickAfter, int24(-100), "tick advanced from start");
    }

    // ----------------------------------------------------------------------
    // Unlock callback
    // ----------------------------------------------------------------------

    function test_UnlockCallbackRevertsForNonPoolManager() public {
        vm.expectRevert(Fountain.InvalidUnlockCaller.selector);
        fountain.unlockCallback("");
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------

    function _offerTwoFlip() internal {
        // token > zeros → flip case.
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 300;
        ticks[2] = 500;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        _mint(3e18);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(zeros), ticks, amounts);
    }

    function _offerTwoNoFlip() internal {
        // token < ffffff → no-flip case.
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 300;
        ticks[2] = 500;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        _mint(3e18);
        bot.offer(Currency.wrap(address(token)), Currency.wrap(ffffff), ticks, amounts);
    }

    function _twoTicks(int24 a, int24 b) internal pure returns (int24[] memory ticks) {
        ticks = new int24[](2);
        ticks[0] = a;
        ticks[1] = b;
    }

    function _oneAmount(uint256 a) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](1);
        amounts[0] = a;
    }

    function _mint(uint256 amt) internal {
        token.mint(address(bot), amt);
    }

    function _keyFor(address quote) internal view returns (PoolKey memory) {
        bool tokenIsCurrency0 = address(token) < quote;
        return PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? address(token) : quote),
            currency1: Currency.wrap(tokenIsCurrency0 ? quote : address(token)),
            fee: fountain.fee(),
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _positionAt(uint256 i) internal view returns (Position memory) {
        Position[] memory slice = fountain.positionsSlice(i, 1);
        return slice[0];
    }
}
