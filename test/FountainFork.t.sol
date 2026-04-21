// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain, Position} from "../src/Fountain.sol";
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
 *         `PoolManagerLookup`, then exercises funding, pre-initialization
 *         guards, validation, the position registry, fee accrual, and
 *         collection across both tick-flip orientations and a native-ETH
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
    int24 internal constant TICK_SPACING = 1;

    function setUp() public override {
        super.setUp();

        bot = new Funder("bot");
        fountain = new Fountain(IAddressLookup(PoolManagerLookup), address(bot));
        bot.setFountain(fountain);
        router = new SwapRouter(fountain.POOL_MANAGER());
        token = _makeToken("MockToken", "MOCK", 18);

        require(ffffff.code.length > 0, "ffffff lepton missing at forked block");
        require(zeros.code.length > 0, "zeros lepton missing at forked block");
    }

    // ----------------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------------

    function test_ConstructorRegistersImmutables() public view {
        assertEq(fountain.OWNER(), address(bot), "OWNER set at construction");
        assertGt(address(fountain.POOL_MANAGER()).code.length, 0, "POOL_MANAGER resolves to live code");
        assertEq(fountain.FEE(), uint24(100), "FEE constant");
    }

    // ----------------------------------------------------------------------
    // Fund — happy path (flip + no-flip + native ETH)
    // ----------------------------------------------------------------------

    function test_FundSingleSegment_NoFlipCase() public {
        // token < ffffff → token is currency0, no flip; V4 ticks = user ticks.
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        uint256 firstId = bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);

        assertEq(firstId, 0, "first position id");
        assertEq(fountain.positionsCount(), 1, "one position created");

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), address(token), "token is currency0");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "ffffff is currency1");
        assertEq(p.tickLower, 100, "tickLower = ticks[0]");
        assertEq(p.tickUpper, 500, "tickUpper = ticks[1]");

        (uint160 sqrtPriceX96,,,) = fountain.POOL_MANAGER().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(100), "starting price = ticks[0]");
    }

    function test_FundSingleSegment_FlipCase() public {
        // token > zeros → token is currency1, flip: V4 = [-ticks[1], -ticks[0]).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.fund(IERC20(address(token)), zeros, TICK_SPACING, ticks, amounts);

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), zeros, "zeros is currency0");
        assertEq(Currency.unwrap(p.key.currency1), address(token), "token is currency1");
        assertEq(p.tickLower, -500, "tickLower = -ticks[1]");
        assertEq(p.tickUpper, -100, "tickUpper = -ticks[0]");

        (uint160 sqrtPriceX96,,,) = fountain.POOL_MANAGER().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-100), "starting price = -ticks[0]");
    }

    function test_FundSingleSegment_NativeETH() public {
        // ETH = address(0) → token > quote, flip: V4 = [-ticks[1], -ticks[0]).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.fund(IERC20(address(token)), address(0), TICK_SPACING, ticks, amounts);

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), address(0), "ETH is currency0");
        assertEq(Currency.unwrap(p.key.currency1), address(token), "token is currency1");
        assertEq(p.tickLower, -500);
        assertEq(p.tickUpper, -100);

        (uint160 sqrtPriceX96,,,) = fountain.POOL_MANAGER().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-100), "starting price = -ticks[0]");
    }

    function test_FundMultiSegment_NoFlipCase() public {
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

        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
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

        (uint160 sqrtPriceX96,,,) = fountain.POOL_MANAGER().getSlot0(p0.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(100), "pool init at ticks[0]");

        // Token supply landed in PoolManager (modulo dust in Fountain).
        uint256 inPoolManager = IERC20(address(token)).balanceOf(address(fountain.POOL_MANAGER()));
        uint256 inFountain = IERC20(address(token)).balanceOf(address(fountain));
        assertEq(inPoolManager + inFountain, total, "supply conserved");
        assertGt(inPoolManager, (total * 999) / 1000, "most supply in PoolManager");
    }

    function test_FundMultiSegment_FlipCase() public {
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

        bot.fund(IERC20(address(token)), zeros, TICK_SPACING, ticks, amounts);
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

        (uint160 sqrtPriceX96,,,) = fountain.POOL_MANAGER().getSlot0(p0.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(-100), "pool init at -ticks[0]");
    }

    // ----------------------------------------------------------------------
    // Pool initialization guard
    // ----------------------------------------------------------------------

    function test_FundIdempotentWhenPreInitAtCorrectPrice() public {
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        PoolKey memory key = _keyFor(ffffff, TICK_SPACING);
        // No-flip case (token < ffffff): starting V4 tick = ticks[0] = 100.
        fountain.POOL_MANAGER().initialize(key, TickMath.getSqrtPriceAtTick(100));

        _mint(SEGMENT_AMOUNT);
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
        assertEq(fountain.positionsCount(), 1, "fund succeeded after matching pre-init");
    }

    function test_FundRevertsOnPreInitializedAtWrongPrice() public {
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        PoolKey memory key = _keyFor(ffffff, TICK_SPACING);
        uint160 griefSqrt = TickMath.getSqrtPriceAtTick(777);
        fountain.POOL_MANAGER().initialize(key, griefSqrt);

        _mint(SEGMENT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Fountain.PoolPreInitialized.selector, griefSqrt));
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
    }

    // ----------------------------------------------------------------------
    // Fund — validation errors
    // ----------------------------------------------------------------------

    function test_FundRevertsOnNoPositions() public {
        int24[] memory ticks = new int24[](0);
        uint256[] memory amounts = new uint256[](0);
        vm.expectRevert(Fountain.NoPositions.selector);
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
    }

    function test_FundRevertsOnLengthMismatch() public {
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.expectRevert(abi.encodeWithSelector(Fountain.TickAmountLengthMismatch.selector, uint256(2), uint256(2)));
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
    }

    function test_FundRevertsOnTickOutOfRange() public {
        int24[] memory ticks = new int24[](2);
        ticks[0] = 100;
        ticks[1] = TickMath.MAX_TICK + 1;
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Fountain.TickOutOfRange.selector, TickMath.MAX_TICK + 1));
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
    }

    function test_FundRevertsOnTickNotAligned() public {
        int24[] memory ticks = new int24[](2);
        ticks[0] = 5;
        ticks[1] = 100;
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(Fountain.TickNotAligned.selector, int24(5), int24(10)));
        bot.fund(IERC20(address(token)), ffffff, int24(10), ticks, amounts);
    }

    function test_FundRevertsOnTicksNotAscending() public {
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 300;
        ticks[2] = 200;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.expectRevert(abi.encodeWithSelector(Fountain.TicksNotAscending.selector, uint256(2), int24(300), int24(200)));
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
    }

    function test_FundRevertsOnTicksEqual() public {
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 100;
        ticks[2] = 200;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 1e18;
        vm.expectRevert(abi.encodeWithSelector(Fountain.TicksNotAscending.selector, uint256(1), int24(100), int24(100)));
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
    }

    function test_FundRevertsOnZeroAmount() public {
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 200;
        ticks[2] = 300;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 0;
        vm.expectRevert(abi.encodeWithSelector(Fountain.ZeroAmount.selector, uint256(1)));
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
    }

    // ----------------------------------------------------------------------
    // Position registry views
    // ----------------------------------------------------------------------

    function test_MultipleFundsAppendToRegistry() public {
        uint256 firstFlipId = _fundTwoFlip();
        assertEq(firstFlipId, 0, "first flip batch starts at 0");
        uint256 firstNoFlipId = _fundTwoNoFlip();
        assertEq(firstNoFlipId, 2, "second batch appended after first");
        assertEq(fountain.positionsCount(), 4, "four positions total");
    }

    function test_PositionsRangeClampBranches() public {
        _fundTwoFlip();
        _fundTwoNoFlip();
        assertEq(fountain.positionsCount(), 4);

        // Full slice.
        Position[] memory all = fountain.positionsRange(0, 4);
        assertEq(all.length, 4, "full slice length");

        // Tail clamp: count runs past the end.
        Position[] memory tail = fountain.positionsRange(2, 10);
        assertEq(tail.length, 2, "tail clamp length");

        // Offset at end and past end → empty.
        assertEq(fountain.positionsRange(4, 5).length, 0, "offset == length empty");
        assertEq(fountain.positionsRange(10, 5).length, 0, "offset past length empty");

        // Zero count → empty.
        assertEq(fountain.positionsRange(0, 0).length, 0, "count == 0 empty");

        // Middle single element.
        Position[] memory mid = fountain.positionsRange(1, 1);
        assertEq(mid.length, 1, "middle single-element length");
    }

    // ----------------------------------------------------------------------
    // Pending fees + collect
    // ----------------------------------------------------------------------

    function test_PendingFeesZeroBeforeSwap() public {
        _fundTwoFlip();
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        (uint256[] memory p0, uint256[] memory p1) = fountain.pendingFees(ids);
        assertEq(p0[0] + p1[0] + p0[1] + p1[1], 0, "no fees accrued before swaps");
    }

    function test_PendingFeesRevertsOnUnknownPosition() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 99;
        vm.expectRevert(abi.encodeWithSelector(Fountain.UnknownPosition.selector, uint256(99)));
        fountain.pendingFees(ids);
    }

    function test_CollectSinglePosition_NoFlipCase() public {
        // token < ffffff (no flip): token=currency0. Buyer spends currency1
        // (ffffff) to receive currency0 (token) → zeroForOne=false.
        // Fees accrue on currency1 (ffffff).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);

        PoolKey memory key = _keyFor(ffffff, TICK_SPACING);
        Trader alice = new Trader("alice", router);
        uint128 amountIn = 1e15;
        deal(ffffff, address(alice), uint256(amountIn));
        alice.swap(key, false, amountIn);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.pendingFees(ids);
        assertEq(pending0[0], 0, "no fees on currency0 (token)");
        assertGt(pending1[0], 0, "fees accrued on currency1 (ffffff)");

        uint256 expected = pending1[0];
        uint256 before = IERC20(ffffff).balanceOf(address(bot));
        bot.collect(0);
        assertEq(IERC20(ffffff).balanceOf(address(bot)) - before, expected, "OWNER received pendingFees[1]");

        (pending0, pending1) = fountain.pendingFees(ids);
        assertEq(pending0[0] + pending1[0], 0, "residual fees after collect");
    }

    function test_CollectSinglePosition_FlipCase() public {
        // token > zeros (flip): token=currency1. Buyer spends currency0
        // (zeros) to receive currency1 (token) → zeroForOne=true. Fees
        // accrue on currency0 (zeros).
        int24[] memory ticks = _twoTicks(100, 500);
        uint256[] memory amounts = _oneAmount(SEGMENT_AMOUNT);
        _mint(SEGMENT_AMOUNT);
        bot.fund(IERC20(address(token)), zeros, TICK_SPACING, ticks, amounts);

        PoolKey memory key = _keyFor(zeros, TICK_SPACING);
        Trader bobby = new Trader("bobby", router);
        uint128 amountIn = 1e15;
        deal(zeros, address(bobby), uint256(amountIn));
        bobby.swap(key, true, amountIn);

        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.pendingFees(ids);
        assertGt(pending0[0], 0, "fees accrued on currency0 (zeros)");
        assertEq(pending1[0], 0, "no fees on currency1 (token)");

        uint256 expected = pending0[0];
        uint256 before = IERC20(zeros).balanceOf(address(bot));
        bot.collect(0);
        assertEq(IERC20(zeros).balanceOf(address(bot)) - before, expected, "OWNER received pendingFees[0]");
    }

    function test_CollectBatchAcrossTwoPools() public {
        // Batch collects across a flip-case pool (zeros quote) and a no-flip
        // pool (ffffff quote) in one unlock.
        uint256 flipFirst = _fundTwoFlip(); // ids 0, 1 against zeros
        uint256 noFlipFirst = _fundTwoNoFlip(); // ids 2, 3 against ffffff
        assertEq(flipFirst, 0);
        assertEq(noFlipFirst, 2);

        PoolKey memory flipKey = _keyFor(zeros, TICK_SPACING);
        PoolKey memory noFlipKey = _keyFor(ffffff, TICK_SPACING);

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
        (uint256[] memory pending0, uint256[] memory pending1) = fountain.pendingFees(ids);
        // Flip pool fees on currency0 (zeros), no-flip pool fees on currency1 (ffffff).
        uint256 expectedZeros = pending0[0] + pending0[1];
        uint256 expectedFfffff = pending1[2] + pending1[3];
        assertGt(expectedZeros, 0, "flip case accrued zeros fees");
        assertGt(expectedFfffff, 0, "no-flip case accrued ffffff fees");

        uint256 ffffffBefore = IERC20(ffffff).balanceOf(address(bot));
        uint256 zerosBefore = IERC20(zeros).balanceOf(address(bot));
        bot.collectBatch(ids);

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

        (pending0, pending1) = fountain.pendingFees(ids);
        uint256 residual;
        for (uint256 i = 0; i < 4; i++) {
            residual += pending0[i] + pending1[i];
        }
        assertEq(residual, 0, "no residual fees after batch collect");
    }

    function test_CollectRevertsOnUnknownPosition() public {
        vm.expectRevert(abi.encodeWithSelector(Fountain.UnknownPosition.selector, uint256(99)));
        bot.collect(99);
    }

    function test_CollectBatchRevertsIfAnyIdUnknown() public {
        _fundTwoFlip();
        uint256[] memory ids = new uint256[](3);
        ids[0] = 0;
        ids[1] = 99;
        ids[2] = 1;
        vm.expectRevert(abi.encodeWithSelector(Fountain.UnknownPosition.selector, uint256(99)));
        bot.collectBatch(ids);
    }

    function test_EmptyCollectBatchIsNoop() public {
        vm.recordLogs();
        bot.collectBatch(new uint256[](0));
        assertEq(vm.getRecordedLogs().length, 0, "empty collectBatch emits nothing");
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
        bot.fund(IERC20(address(token)), zeros, TICK_SPACING, ticks, amounts);
        PoolKey memory key = _keyFor(zeros, TICK_SPACING);

        // Starting V4 tick is -100 (top of position 0 at V4 [-200, -100)).
        // Buyer spending zeros (currency0) for token (currency1) drives the
        // V4 tick downward through positions 0, 1, 2 in order.
        (, int24 tickBefore,,) = fountain.POOL_MANAGER().getSlot0(key.toId());
        assertEq(tickBefore, int24(-100), "starts at -ticks[0]");

        Trader alice = new Trader("alice", router);
        uint128 amountIn = 1e18;
        deal(zeros, address(alice), uint256(amountIn));
        alice.swap(key, true, amountIn);

        (, int24 tickAfter,,) = fountain.POOL_MANAGER().getSlot0(key.toId());
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

    function _fundTwoFlip() internal returns (uint256 firstId) {
        // token > zeros → flip case.
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 300;
        ticks[2] = 500;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        _mint(3e18);
        firstId = bot.fund(IERC20(address(token)), zeros, TICK_SPACING, ticks, amounts);
    }

    function _fundTwoNoFlip() internal returns (uint256 firstId) {
        // token < ffffff → no-flip case.
        int24[] memory ticks = new int24[](3);
        ticks[0] = 100;
        ticks[1] = 300;
        ticks[2] = 500;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1e18;
        amounts[1] = 2e18;
        _mint(3e18);
        firstId = bot.fund(IERC20(address(token)), ffffff, TICK_SPACING, ticks, amounts);
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

    function _keyFor(address quote, int24 tickSpacing) internal view returns (PoolKey memory) {
        bool tokenIsCurrency0 = address(token) < quote;
        return PoolKey({
            currency0: Currency.wrap(tokenIsCurrency0 ? address(token) : quote),
            currency1: Currency.wrap(tokenIsCurrency0 ? quote : address(token)),
            fee: fountain.FEE(),
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });
    }

    function _positionAt(uint256 i) internal view returns (Position memory) {
        Position[] memory slice = fountain.positionsRange(i, 1);
        return slice[0];
    }
}
