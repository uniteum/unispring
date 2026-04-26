// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {NeutrinoChannel} from "../src/NeutrinoChannel.sol";
import {TestToken} from "./TestToken.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Mock coinage that records mint calls and returns a fresh {TestToken}
 *         with the requested supply pre-minted to the caller.
 */
contract MockCoinage is ICoinage {
    TestToken public lastToken;

    function made(address, string calldata, string calldata, uint8, uint256, bytes32)
        external
        pure
        returns (bool, address, bytes32)
    {
        revert();
    }

    function make(string calldata name, string calldata symbol, uint8 decimals, uint256 supply, bytes32)
        external
        returns (IERC20Metadata token)
    {
        TestToken t = new TestToken(name, symbol, decimals);
        t.mint(msg.sender, supply);
        lastToken = t;
        return IERC20Metadata(address(t));
    }
}

contract NeutrinoChannelTest is Test {
    NeutrinoChannel internal proto;
    MockCoinage internal coinage;

    function setUp() public {
        proto = new NeutrinoChannel();
        coinage = new MockCoinage();
    }

    // ---- proto immutable ----

    function test_ProtoPointsToSelf() public view {
        assertEq(address(proto.proto()), address(proto));
    }

    // ---- made / make ----

    function test_MadePredictsDeterministicAddress() public view {
        (bool exists, address home,) = proto.made(address(this), int24(-100), int24(100));
        assertFalse(exists, "clone should not exist yet");
        assertTrue(home != address(0), "predicted address should be non-zero");
    }

    function test_MakeDeploysClone() public {
        NeutrinoChannel clone = proto.make(int24(-100), int24(100));
        (bool exists, address home,) = proto.made(address(this), int24(-100), int24(100));
        assertTrue(exists, "clone should exist after make");
        assertEq(address(clone), home, "clone address should match prediction");
    }

    function test_MakeIsIdempotent() public {
        NeutrinoChannel clone1 = proto.make(int24(-100), int24(100));
        NeutrinoChannel clone2 = proto.make(int24(-100), int24(100));
        assertEq(address(clone1), address(clone2), "idempotent make should return same clone");
    }

    function test_MakeSetsCorrectSource() public {
        NeutrinoChannel clone = proto.make(int24(-100), int24(100));
        assertEq(clone.source(), address(this), "source should be msg.sender of make");
    }

    function test_DifferentTicksProduceDifferentClones() public {
        NeutrinoChannel cloneA = proto.make(int24(-100), int24(100));
        NeutrinoChannel cloneB = proto.make(int24(-200), int24(200));
        assertTrue(address(cloneA) != address(cloneB), "different ticks should produce different clones");
    }

    function test_DifferentSendersProduceDifferentClones() public {
        NeutrinoChannel cloneA = proto.make(int24(-100), int24(100));

        vm.prank(address(0xBEEF));
        NeutrinoChannel cloneB = proto.make(int24(-100), int24(100));

        assertTrue(address(cloneA) != address(cloneB), "different senders should produce different clones");
    }

    // ---- zzInit ----

    function test_ZzInitRevertsIfNotCalledByProto() public {
        NeutrinoChannel clone = proto.make(int24(-100), int24(100));
        vm.expectRevert(NeutrinoChannel.Unauthorized.selector);
        clone.zzInit(address(this));
    }

    // ---- mint ----

    function test_MintRelaysToCoinageAndTransfersSupply() public {
        NeutrinoChannel clone = proto.make(int24(-100), int24(100));
        uint256 supply = 1_000_000 ether;

        IERC20Metadata token = clone.mint(coinage, "TestToken", "TT", 18, supply, bytes32(0));

        // Token was created via coinage.
        assertEq(address(token), address(coinage.lastToken()), "token should come from coinage");
        // Entire supply forwarded to the caller (this contract, the source).
        assertEq(TestToken(address(token)).balanceOf(address(this)), supply, "source should hold full supply");
        assertEq(TestToken(address(token)).balanceOf(address(clone)), 0, "clone should hold zero");
    }

    function test_MintRevertsIfCallerIsNotSource() public {
        NeutrinoChannel clone = proto.make(int24(-100), int24(100));
        vm.prank(address(0xBEEF));
        vm.expectRevert(NeutrinoChannel.Unauthorized.selector);
        clone.mint(coinage, "TestToken", "TT", 18, 1 ether, bytes32(0));
    }
}
