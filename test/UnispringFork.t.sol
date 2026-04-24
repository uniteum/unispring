// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain, Position} from "../src/Fountain.sol";
import {Unispring} from "../src/Unispring.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {Funder} from "./Funder.sol";
import {TestToken} from "./TestToken.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @notice Fork test against mainnet state. Deploys a fresh Fountain and a
 *         fresh Unispring prototype against the real PoolManager, then
 *         exercises the clone-per-hub factory: hub pool seated by {zzInit}
 *         (ETH/hub, hub above ETH → flip case in Fountain), spoke pools
 *         seated by {fund} (spoke/hub, spoke below hub → identity).
 *
 *         Run with:
 *           forge test --match-contract UnispringForkTest -f mainnet -vv
 *         or pin a block:
 *           FORK_BLOCK=24923365 forge test --match-contract UnispringForkTest -f mainnet -vv
 */
contract UnispringForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    Fountain internal fountain;
    Unispring internal proto;
    Funder internal bot;

    uint256 internal constant HUB_SUPPLY = 10_000_000 ether;
    int24 internal constant HUB_TICK_LOWER = TickMath.MIN_TICK + 1;
    int24 internal constant HUB_TICK_UPPER = 60_000;

    function setUp() public override {
        super.setUp();

        bot = new Funder("bot");
        Fountain fountainProto = new Fountain(IAddressLookup(PoolManagerLookup));
        bot.makeFountain(fountainProto);
        fountain = bot.fountain();
        proto = new Unispring(fountain);

        require(ffffff.code.length > 0, "ffffff lepton missing at forked block");
    }

    // ----------------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------------

    function test_ConstructorRegistersImmutables() public view {
        assertEq(address(proto.PROTO()), address(proto), "PROTO is self on prototype");
        assertEq(address(proto.FOUNTAIN()), address(fountain), "FOUNTAIN immutable");
        assertEq(proto.hub(), address(0), "hub unset on prototype");
    }

    // ----------------------------------------------------------------------
    // make / zzInit — hub pool seated against ETH
    // ----------------------------------------------------------------------

    function test_MakeSeatsHubPoolAgainstETH() public {
        Unispring clone = _makeHub();

        assertEq(clone.hub(), ffffff, "clone hub set");
        assertEq(fountain.positionsCount(), 1, "one position seated by zzInit");

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), address(0), "currency0 = ETH");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "currency1 = hub");
        assertEq(p.tickLower, HUB_TICK_LOWER, "V4 tickLower preserved through flip");
        assertEq(p.tickUpper, HUB_TICK_UPPER, "V4 tickUpper preserved through flip");

        // Pool sits at the upper edge — single-sided in hub, inactive at spot.
        (uint160 sqrtPriceX96,,,) = fountain.POOL_MANAGER().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(HUB_TICK_UPPER), "pool starts at V4 upper tick");

        // Hub supply landed in the PoolManager (modulo dust in Fountain).
        uint256 inPoolManager = IERC20(ffffff).balanceOf(address(fountain.POOL_MANAGER()));
        uint256 inFountain = IERC20(ffffff).balanceOf(address(fountain));
        uint256 inClone = IERC20(ffffff).balanceOf(address(clone));
        assertEq(inPoolManager + inFountain + inClone, HUB_SUPPLY, "hub supply conserved");
        assertGt(inPoolManager, (HUB_SUPPLY * 999) / 1000, "most of supply in PoolManager");
    }

    function test_MakeIsIdempotent() public {
        Unispring first = _makeHub();
        Unispring second = proto.make(IERC20(ffffff), HUB_TICK_LOWER, HUB_TICK_UPPER);
        assertEq(address(first), address(second), "make idempotent: same clone");
        assertEq(fountain.positionsCount(), 1, "second make does not re-seat hub");
    }

    function test_MakeFromCloneDelegatesToProto() public {
        Unispring clone = _makeHub();
        Unispring same = clone.make(IERC20(ffffff), HUB_TICK_LOWER, HUB_TICK_UPPER);
        assertEq(address(same), address(clone), "clone.make routes through PROTO");
    }

    // ----------------------------------------------------------------------
    // fund — spoke pool paired against hub
    // ----------------------------------------------------------------------

    function test_FundSpokeSeatsPositionAgainstHub() public {
        Unispring clone = _makeHub();

        TestToken spoke = _makeToken("Spoke", "SPK", 18);
        uint256 supply = 1_000_000 ether;
        int24 tickLower = -120_000;
        int24 tickUpper = TickMath.MAX_TICK - 1;
        spoke.mint(address(this), supply);
        spoke.approve(address(clone), supply);

        uint256 positionId = clone.fund(Currency.wrap(address(spoke)), supply, tickLower, tickUpper);

        assertEq(positionId, 1, "spoke is the second position");
        assertEq(fountain.positionsCount(), 2, "hub + spoke");

        Position memory p = _positionAt(1);
        assertEq(Currency.unwrap(p.key.currency0), address(spoke), "spoke is currency0");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "hub is currency1");
        assertEq(p.tickLower, tickLower, "V4 tickLower = user tickLower (no flip)");
        assertEq(p.tickUpper, tickUpper, "V4 tickUpper = user tickUpper (no flip)");

        // Pool sits at the lower edge — single-sided in spoke, inactive at spot.
        (uint160 sqrtPriceX96,,,) = fountain.POOL_MANAGER().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), "pool starts at V4 lower tick");

        // Caller's spoke supply ended up in PoolManager.
        assertGt(IERC20(address(spoke)).balanceOf(address(fountain.POOL_MANAGER())), 0, "spoke in PoolManager");
        assertEq(IERC20(address(spoke)).balanceOf(address(this)), 0, "caller debited fully");
    }

    /**
     * @notice Native ETH as the spoke: caller sends `supply` as `msg.value`
     *         and Unispring forwards through Fountain which settles via
     *         `settle{value:}`. The spoke pool is `(ETH, hub)` — the same
     *         currency pair as the hub's own ETH pool seated by {zzInit}, so
     *         this lands on a pre-initialized pool and only succeeds when the
     *         spoke's lower-edge price matches the hub pool's current price.
     *         We pin `tickLower = HUB_TICK_UPPER` to satisfy that constraint
     *         and verify ETH lands in the PoolManager via the native-settle
     *         path on a fresh position id.
     */
    function test_FundSeatsNativeETHSpokeAgainstHub() public {
        Unispring clone = _makeHub();

        uint256 supply = 1_000_000 ether;
        // Spoke V4 tickLower must equal the hub pool's init tick (HUB_TICK_UPPER
        // after the hub-side negate-and-swap maps to V4 tick HUB_TICK_UPPER).
        int24 tickLower = HUB_TICK_UPPER;
        int24 tickUpper = TickMath.MAX_TICK - 1;
        vm.deal(address(this), supply);
        uint256 pmBefore = address(fountain.POOL_MANAGER()).balance;

        uint256 positionId = clone.fund{value: supply}(Currency.wrap(address(0)), supply, tickLower, tickUpper);

        assertEq(positionId, 1, "spoke is the second position");
        assertEq(fountain.positionsCount(), 2, "hub + spoke");

        Position memory p = _positionAt(1);
        assertEq(Currency.unwrap(p.key.currency0), address(0), "ETH spoke is currency0");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "hub is currency1");
        assertEq(p.tickLower, tickLower, "V4 tickLower = user tickLower (no flip)");
        assertEq(p.tickUpper, tickUpper, "V4 tickUpper = user tickUpper (no flip)");

        uint256 pmDelta = address(fountain.POOL_MANAGER()).balance - pmBefore;
        assertGt(pmDelta, (supply * 999) / 1000, "most ETH in PoolManager");
        assertEq(address(this).balance, 0, "caller debited fully");
    }

    /**
     * @notice ERC-20 spoke must not receive native value — Fountain reverts
     *         with {Fountain.NativeValueMismatch} when forwarded a non-zero
     *         `msg.value`.
     */
    function test_FundRevertsWhenERC20SpokeSentNativeValue() public {
        Unispring clone = _makeHub();
        TestToken spoke = _makeToken("Spoke", "SPK", 18);
        uint256 supply = 1 ether;
        spoke.mint(address(this), supply);
        spoke.approve(address(clone), supply);
        vm.deal(address(this), 1);
        vm.expectRevert(abi.encodeWithSelector(Fountain.NativeValueMismatch.selector, uint256(0), uint256(1)));
        clone.fund{value: 1}(Currency.wrap(address(spoke)), supply, -120_000, TickMath.MAX_TICK - 1);
    }

    // ----------------------------------------------------------------------
    // fund — validation
    // ----------------------------------------------------------------------

    function test_FundRevertsOnSpokeAboveHub() public {
        // Use a low-address hub so almost any spoke sorts above it.
        Unispring clone = _makeHubAt(zeros);
        Currency bogusSpoke = Currency.wrap(ffffff);

        vm.expectRevert(abi.encodeWithSelector(Unispring.SpokeMustSortBelowHub.selector, Currency.unwrap(bogusSpoke)));
        clone.fund(bogusSpoke, 0, -100, 100);
    }

    function test_FundRevertsOnInvertedTicks() public {
        Unispring clone = _makeHub();
        TestToken spoke = _makeToken("Spoke", "SPK", 18);

        vm.expectRevert(abi.encodeWithSelector(Unispring.TickLowerNotBelowUpper.selector, int24(100), int24(50)));
        clone.fund(Currency.wrap(address(spoke)), 0, 100, 50);
    }

    function test_FundRevertsOnEqualTicks() public {
        Unispring clone = _makeHub();
        TestToken spoke = _makeToken("Spoke", "SPK", 18);

        vm.expectRevert(abi.encodeWithSelector(Unispring.TickLowerNotBelowUpper.selector, int24(100), int24(100)));
        clone.fund(Currency.wrap(address(spoke)), 0, 100, 100);
    }

    function test_ZzInitRevertsIfNotCalledByProto() public {
        Unispring clone = _makeHub();
        vm.expectRevert(Unispring.Unauthorized.selector);
        clone.zzInit(IERC20(ffffff), HUB_TICK_LOWER, HUB_TICK_UPPER);
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------

    function _makeHub() internal returns (Unispring clone) {
        clone = _makeHubAt(ffffff);
    }

    function _makeHubAt(address hub) internal returns (Unispring clone) {
        IERC20 hubToken = IERC20(hub);
        (, address home,) = proto.made(hubToken, HUB_TICK_LOWER, HUB_TICK_UPPER);
        deal(hub, home, HUB_SUPPLY);
        clone = proto.make(hubToken, HUB_TICK_LOWER, HUB_TICK_UPPER);
    }

    function _positionAt(uint256 i) internal view returns (Position memory) {
        Position[] memory slice = fountain.positionsRange(i, 1);
        return slice[0];
    }
}
