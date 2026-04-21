// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {TestToken} from "./TestToken.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @notice Minimal stand-in for the Uniswap V4 PoolManager. Implements just the
 *         subset of selectors that Unispring touches: `initialize`, `unlock`,
 *         `modifyLiquidity`, `sync`, `settle`.
 *
 *         Records the last init/modify args so the test can assert on them, and
 *         performs minimal settlement bookkeeping for the single-sided positions
 *         that Unispring funds.
 */
contract MockPoolManager {
    struct Initialize {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        bool seen;
    }

    struct Modify {
        PoolId poolId;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bool seen;
    }

    Initialize public lastInit;
    Modify public lastModify;

    // Slot0 snapshots keyed by poolId, used to decide single-sided fund direction.
    mapping(PoolId => uint160) public sqrtPriceOf;

    // Mock extsload storage for StateLibrary compatibility.
    mapping(bytes32 => bytes32) internal _slots;

    Currency internal _synced;

    error PoolAlreadyInitialized();

    function extsload(bytes32 slot) external view returns (bytes32) {
        // Iterate over tracked pools to match the StateLibrary slot layout.
        // StateLibrary.POOLS_SLOT = 6; slot0 is at offset 0 within the pool state.
        // stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), bytes32(uint256(6))))
        // This is a test-only mock — production uses real storage via extsload.
        return _slots[slot];
    }

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        if (sqrtPriceOf[key.toId()] != 0) revert PoolAlreadyInitialized();
        lastInit = Initialize({
            currency0: key.currency0,
            currency1: key.currency1,
            fee: key.fee,
            tickSpacing: key.tickSpacing,
            sqrtPriceX96: sqrtPriceX96,
            seen: true
        });
        sqrtPriceOf[key.toId()] = sqrtPriceX96;
        tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // Populate extsload slot so StateLibrary.getSlot0 works.
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(key.toId()), bytes32(uint256(6))));
        // forge-lint: disable-next-line(unsafe-typecast)
        _slots[stateSlot] = bytes32(uint256(sqrtPriceX96) | (uint256(uint24(int24(tick))) << 160));
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        lastModify = Modify({
            poolId: key.toId(),
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: params.liquidityDelta,
            seen: true
        });

        // Funding path. Decide which side the position is single-sided in by
        // inspecting the initialization tick. If the pool's price tick sits at
        // the lower bound the position is in currency0; otherwise currency1.
        bool isLowerBound = sqrtPriceOf[key.toId()] == TickMath.getSqrtPriceAtTick(params.tickLower);

        int128 owed = -int128(uint128(uint256(params.liquidityDelta)));
        callerDelta = isLowerBound ? toBalanceDelta(owed, int128(0)) : toBalanceDelta(int128(0), owed);
        feesAccrued = toBalanceDelta(int128(0), int128(0));
    }

    function sync(Currency currency) external {
        _synced = currency;
    }

    function settle() external payable returns (uint256 paid) {
        // Pull the entire balance the caller pre-funded us with for the synced currency.
        Currency c = _synced;
        if (Currency.unwrap(c) == address(0)) {
            paid = msg.value;
        } else {
            address tok = Currency.unwrap(c);
            paid = TestToken(tok).balanceOf(address(this));
        }
    }
}

contract UnispringTest is Test {
    Unispring internal unispring;
    MockPoolManager internal pm;

    address internal constant HUB_ADDR = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    address internal constant SPOKE_TOKEN_ADDR = 0x1111111111111111111111111111111111111111;
    address internal constant LOOKUP_ADDR = 0xd6185883DD1Fa3F6F4F0b646f94D1fb46d618c23;

    uint256 internal constant HUB_SUPPLY = 10_000_000 ether;
    int24 internal constant HUB_TICK_FLOOR = -60_000;

    function setUp() public {
        // 1. Deploy the mock PoolManager and mock the lookup constant.
        pm = new MockPoolManager();
        vm.mockCall(LOOKUP_ADDR, abi.encodeWithSelector(IAddressLookup.value.selector), abi.encode(address(pm)));

        // 2. Etch a TestToken at the fixed HUB address so it has working ERC-20 code.
        TestToken template = new TestToken("", "", 18);
        vm.etch(HUB_ADDR, address(template).code);

        // 3. Construct the prototype, pre-fund the clone, then make (funds hub in zzInit).
        Unispring proto = new Unispring(IAddressLookup(LOOKUP_ADDR));
        int24 tickLower = TickMath.MIN_TICK + 1;
        int24 tickUpper = -HUB_TICK_FLOOR;
        (, address home,) = proto.made(IERC20(HUB_ADDR), tickLower, tickUpper);
        TestToken(HUB_ADDR).mint(home, HUB_SUPPLY);
        unispring = proto.make(IERC20(HUB_ADDR), tickLower, tickUpper);

        // 5. Etch a second TestToken at the fixed spoke-token address, below HUB_ADDR,
        //    ready for upcoming `fund` calls.
        vm.etch(SPOKE_TOKEN_ADDR, address(template).code);
    }

    function test_ConstructorRegistersImmutables() public view {
        assertEq(unispring.hub(), HUB_ADDR, "HUB immutable");
    }

    function test_FundInitializesPoolAndAddsLiquidity() public {
        uint256 supply = 1_000_000 ether;
        int24 tickFloor = -120_000;

        // Mint spoke supply to this test contract and approve Unispring to pull it.
        TestToken(SPOKE_TOKEN_ADDR).mint(address(this), supply);
        TestToken(SPOKE_TOKEN_ADDR).approve(address(unispring), supply);

        int24 tickUpper = TickMath.MAX_TICK - 1;
        unispring.fund(IERC20(SPOKE_TOKEN_ADDR), supply, tickFloor, tickUpper);

        // Pool was initialized with the right key shape.
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96, bool seenInit) =
            pm.lastInit();
        assertTrue(seenInit, "initialize not called");
        assertEq(fee, unispring.FEE(), "fee constant mismatch");
        assertEq(tickSpacing, 1, "tickSpacing must be 1");

        // Spoke token must sort strictly below HUB so it lands as currency0.
        assertLt(uint160(SPOKE_TOKEN_ADDR), uint160(unispring.hub()), "spoke must sort below HUB");
        assertEq(Currency.unwrap(currency0), SPOKE_TOKEN_ADDR);
        assertEq(Currency.unwrap(currency1), unispring.hub());
        // Single-sided in currency0 → pool price sits at the lower bound (tickFloor).
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickFloor));

        // Liquidity was added with positive delta and the right tick range.
        (, int24 tickLower_, int24 tickUpper_, int256 liquidityDelta, bool seenModify) = pm.lastModify();
        assertTrue(seenModify, "modifyLiquidity not called");
        assertGt(liquidityDelta, 0, "liquidityDelta must be positive");
        assertEq(tickLower_, tickFloor);
        assertEq(tickUpper_, tickUpper);

        // The caller settled by transferring spoke tokens to the (mock) PoolManager.
        uint256 pmBalance = TestToken(SPOKE_TOKEN_ADDR).balanceOf(address(pm));
        uint256 leftover = TestToken(SPOKE_TOKEN_ADDR).balanceOf(address(unispring));
        assertEq(pmBalance + leftover, supply, "supply must be conserved");
        assertGt(pmBalance, 0, "PoolManager received zero tokens");
    }
}
