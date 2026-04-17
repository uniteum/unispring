// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICoinage} from "ierc20/ICoinage.sol";
import {NeutrinoMaker} from "../src/NeutrinoMaker.sol";
import {Test} from "forge-std/Test.sol";

/**
 * @notice Mock lepton that records mint calls and returns a mock token.
 */
contract MockLepton {
    MockMintedToken public lastToken;

    function make(string calldata name, string calldata symbol, uint256 supply, bytes32)
        external
        returns (ICoinage token)
    {
        MockMintedToken t = new MockMintedToken(name, symbol, supply, msg.sender);
        lastToken = t;
        return ICoinage(address(t));
    }
}

/**
 * @notice Minimal ERC-20 that mints supply to a given recipient on construction.
 */
contract MockMintedToken {
    string public name;
    string public symbol;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient) {
        name = name_;
        symbol = symbol_;
        totalSupply = supply_;
        balanceOf[recipient] = supply_;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract NeutrinoMakerTest is Test {
    NeutrinoMaker internal proto;
    MockLepton internal lepton;

    function setUp() public {
        proto = new NeutrinoMaker();
        lepton = new MockLepton();
    }

    // ---- PROTO immutable ----

    function test_ProtoPointsToSelf() public view {
        assertEq(address(proto.PROTO()), address(proto));
    }

    // ---- made / make ----

    function test_MadePredictsDeterministicAddress() public view {
        (bool exists, address home,) = proto.made(address(this), int24(-100), int24(100));
        assertFalse(exists, "clone should not exist yet");
        assertTrue(home != address(0), "predicted address should be non-zero");
    }

    function test_MakeDeploysClone() public {
        NeutrinoMaker clone = proto.make(int24(-100), int24(100));
        (bool exists, address home,) = proto.made(address(this), int24(-100), int24(100));
        assertTrue(exists, "clone should exist after make");
        assertEq(address(clone), home, "clone address should match prediction");
    }

    function test_MakeIsIdempotent() public {
        NeutrinoMaker clone1 = proto.make(int24(-100), int24(100));
        NeutrinoMaker clone2 = proto.make(int24(-100), int24(100));
        assertEq(address(clone1), address(clone2), "idempotent make should return same clone");
    }

    function test_MakeSetsCorrectMaker() public {
        NeutrinoMaker clone = proto.make(int24(-100), int24(100));
        assertEq(clone.maker(), address(this), "maker should be msg.sender of make");
    }

    function test_DifferentTicksProduceDifferentClones() public {
        NeutrinoMaker cloneA = proto.make(int24(-100), int24(100));
        NeutrinoMaker cloneB = proto.make(int24(-200), int24(200));
        assertTrue(address(cloneA) != address(cloneB), "different ticks should produce different clones");
    }

    function test_DifferentSendersProduceDifferentClones() public {
        NeutrinoMaker cloneA = proto.make(int24(-100), int24(100));

        vm.prank(address(0xBEEF));
        NeutrinoMaker cloneB = proto.make(int24(-100), int24(100));

        assertTrue(address(cloneA) != address(cloneB), "different senders should produce different clones");
    }

    // ---- zzInit ----

    function test_ZzInitRevertsIfNotCalledByProto() public {
        NeutrinoMaker clone = proto.make(int24(-100), int24(100));
        vm.expectRevert(NeutrinoMaker.Unauthorized.selector);
        clone.zzInit(address(this));
    }

    // ---- mint ----

    function test_MintRelaysToLeptonAndTransfersSupply() public {
        NeutrinoMaker clone = proto.make(int24(-100), int24(100));
        uint256 supply = 1_000_000 ether;

        ICoinage token = clone.mint(ICoinage(address(lepton)), "TestToken", "TT", supply, bytes32(0));

        // Token was created via lepton.
        assertEq(address(token), address(lepton.lastToken()), "token should come from lepton");
        // Entire supply forwarded to the caller (this contract, the maker).
        assertEq(MockMintedToken(address(token)).balanceOf(address(this)), supply, "maker should hold full supply");
        assertEq(MockMintedToken(address(token)).balanceOf(address(clone)), 0, "clone should hold zero");
    }

    function test_MintRevertsIfCallerIsNotMaker() public {
        NeutrinoMaker clone = proto.make(int24(-100), int24(100));
        vm.prank(address(0xBEEF));
        vm.expectRevert(NeutrinoMaker.Unauthorized.selector);
        clone.mint(ICoinage(address(lepton)), "TestToken", "TT", 1 ether, bytes32(0));
    }
}
