// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Fountain} from "../src/Fountain.sol";
import {Position} from "../src/IFeeTaker.sol";
import {Manifold} from "../src/Manifold.sol";
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
 *         fresh Manifold prototype against the real PoolManager, then
 *         exercises the clone-per-hub factory: hub pool seated by {zzInit}
 *         (ETH/hub, hub above ETH → flip case in Fountain), spoke pools
 *         seated by {offer} (spoke/hub, spoke below hub → identity).
 *
 *         Run with:
 *           forge test --match-contract ManifoldForkTest -f mainnet -vv
 *         or pin a block:
 *           FORK_BLOCK=24923365 forge test --match-contract ManifoldForkTest -f mainnet -vv
 */
contract ManifoldForkTest is ForkBase {
    using StateLibrary for IPoolManager;

    Fountain internal fountain;
    Manifold internal proto;
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
        proto = new Manifold(fountain);

        require(ffffff.code.length > 0, "ffffff lepton missing at forked block");
    }

    // ----------------------------------------------------------------------
    // Construction
    // ----------------------------------------------------------------------

    function test_ConstructorRegistersImmutables() public view {
        assertEq(address(proto.proto()), address(proto), "proto is self on prototype");
        assertEq(address(proto.placer()), address(fountain), "placer immutable");
        assertEq(proto.hub(), address(0), "hub unset on prototype");
    }

    // ----------------------------------------------------------------------
    // make / zzInit — hub pool seated against ETH
    // ----------------------------------------------------------------------

    function test_MakeSeatsHubPoolAgainstETH() public {
        Manifold clone = _makeHub();

        assertEq(clone.hub(), ffffff, "clone hub set");
        assertEq(fountain.positionsCount(), 1, "one position seated by zzInit");

        Position memory p = _positionAt(0);
        assertEq(Currency.unwrap(p.key.currency0), address(0), "currency0 = ETH");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "currency1 = hub");
        assertEq(p.tickLower, HUB_TICK_LOWER, "V4 tickLower preserved through flip");
        assertEq(p.tickUpper, HUB_TICK_UPPER, "V4 tickUpper preserved through flip");

        // Pool sits at the upper edge — single-sided in hub, inactive at spot.
        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(HUB_TICK_UPPER), "pool starts at V4 upper tick");

        // Hub supply landed in the PoolManager (modulo dust in Fountain).
        uint256 inPoolManager = IERC20(ffffff).balanceOf(address(fountain.poolManager()));
        uint256 inFountain = IERC20(ffffff).balanceOf(address(fountain));
        uint256 inClone = IERC20(ffffff).balanceOf(address(clone));
        assertEq(inPoolManager + inFountain + inClone, HUB_SUPPLY, "hub supply conserved");
        assertGt(inPoolManager, (HUB_SUPPLY * 999) / 1000, "most of supply in PoolManager");
    }

    function test_MakeIsIdempotent() public {
        Manifold first = _makeHub();
        Manifold second = proto.make(IERC20(ffffff), HUB_TICK_LOWER, HUB_TICK_UPPER);
        assertEq(address(first), address(second), "make idempotent: same clone");
        assertEq(fountain.positionsCount(), 1, "second make does not re-seat hub");
    }

    function test_MakeFromCloneDelegatesToProto() public {
        Manifold clone = _makeHub();
        Manifold same = clone.make(IERC20(ffffff), HUB_TICK_LOWER, HUB_TICK_UPPER);
        assertEq(address(same), address(clone), "clone.make routes through proto");
    }

    // ----------------------------------------------------------------------
    // offer — spoke pool paired against hub
    // ----------------------------------------------------------------------

    function test_OfferSpokeSeatsPositionAgainstHub() public {
        Manifold clone = _makeHub();

        TestToken spoke = _makeToken("Spoke", "SPK", 18);
        uint256 supply = 1_000_000 ether;
        int24 tickLower = -120_000;
        int24 tickUpper = TickMath.MAX_TICK - 1;
        spoke.mint(address(this), supply);
        spoke.approve(address(clone), supply);

        clone.offer(Currency.wrap(address(spoke)), supply, tickLower, tickUpper);

        assertEq(fountain.positionsCount(), 2, "hub + spoke");

        Position memory p = _positionAt(1);
        assertEq(Currency.unwrap(p.key.currency0), address(spoke), "spoke is currency0");
        assertEq(Currency.unwrap(p.key.currency1), ffffff, "hub is currency1");
        assertEq(p.tickLower, tickLower, "V4 tickLower = user tickLower (no flip)");
        assertEq(p.tickUpper, tickUpper, "V4 tickUpper = user tickUpper (no flip)");

        // Pool sits at the lower edge — single-sided in spoke, inactive at spot.
        (uint160 sqrtPriceX96,,,) = fountain.poolManager().getSlot0(p.key.toId());
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickLower), "pool starts at V4 lower tick");

        // Caller's spoke supply ended up in PoolManager.
        assertGt(IERC20(address(spoke)).balanceOf(address(fountain.poolManager())), 0, "spoke in PoolManager");
        assertEq(IERC20(address(spoke)).balanceOf(address(this)), 0, "caller debited fully");
    }

    // ----------------------------------------------------------------------
    // offer — validation
    // ----------------------------------------------------------------------

    function test_OfferRevertsOnSpokeAboveHub() public {
        // Use a low-address hub so almost any spoke sorts above it.
        Manifold clone = _makeHubAt(zeros);
        Currency bogusSpoke = Currency.wrap(ffffff);

        vm.expectRevert(abi.encodeWithSelector(Manifold.SpokeMustSortBelowHub.selector, Currency.unwrap(bogusSpoke)));
        clone.offer(bogusSpoke, 0, -100, 100);
    }

    function test_OfferRevertsOnInvertedTicks() public {
        Manifold clone = _makeHub();
        TestToken spoke = _makeToken("Spoke", "SPK", 18);

        vm.expectRevert(abi.encodeWithSelector(Manifold.TickLowerNotBelowUpper.selector, int24(100), int24(50)));
        clone.offer(Currency.wrap(address(spoke)), 0, 100, 50);
    }

    function test_OfferRevertsOnEqualTicks() public {
        Manifold clone = _makeHub();
        TestToken spoke = _makeToken("Spoke", "SPK", 18);

        vm.expectRevert(abi.encodeWithSelector(Manifold.TickLowerNotBelowUpper.selector, int24(100), int24(100)));
        clone.offer(Currency.wrap(address(spoke)), 0, 100, 100);
    }

    function test_ZzInitRevertsIfNotCalledByProto() public {
        Manifold clone = _makeHub();
        vm.expectRevert(Manifold.Unauthorized.selector);
        clone.zzInit(IERC20(ffffff), HUB_TICK_LOWER, HUB_TICK_UPPER);
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------

    function _makeHub() internal returns (Manifold clone) {
        clone = _makeHubAt(ffffff);
    }

    function _makeHubAt(address hub) internal returns (Manifold clone) {
        IERC20 hubToken = IERC20(hub);
        (, address home,) = proto.made(hubToken, HUB_TICK_LOWER, HUB_TICK_UPPER);
        deal(hub, home, HUB_SUPPLY);
        clone = proto.make(hubToken, HUB_TICK_LOWER, HUB_TICK_UPPER);
    }

    function _positionAt(uint256 i) internal view returns (Position memory) {
        Position[] memory slice = fountain.positionsSlice(i, 1);
        return slice[0];
    }
}
