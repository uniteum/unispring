// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @notice Minimal mintable ERC-20 used in place of a real Lepton clone.
 */
contract MockToken {
    string public name;
    string public symbol;
    // forge-lint: disable-next-line(screaming-snake-case-const)
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        allowance[from][msg.sender] -= amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/**
 * @notice Stand-in for Lepton. Returns a pre-set token and mints supply to the caller.
 *         Reads the address to return from storage slot 0 so that {setReturn}
 *         can be called between invocations to rotate the returned token.
 */
contract MockCoinage {
    function setReturn(address t) external {
        assembly {
            sstore(0, t)
        }
    }

    function make(string calldata, string calldata, uint256 supply, bytes32) external returns (address t) {
        assembly {
            t := sload(0)
        }
        MockToken(t).mint(msg.sender, supply);
    }

    function made(address, string calldata, string calldata, uint256, bytes32)
        external
        pure
        returns (bool, address, bytes32)
    {
        return (false, address(0), bytes32(0));
    }
}

/**
 * @notice Minimal stand-in for the Uniswap V4 PoolManager. Implements just the
 *         subset of selectors that Unispring touches: `initialize`, `unlock`,
 *         `modifyLiquidity`, `sync`, `settle`, `take`, and extsload (for
 *         `StateLibrary.getSlot0` during {plow}).
 *
 *         Records the last init/modify args so the test can assert on them, and
 *         performs minimal settlement bookkeeping for the single-sided seeds
 *         that Unispring creates.
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

    // Slot0 snapshots keyed by poolId, used by StateLibrary.getSlot0 via extsload.
    mapping(PoolId => uint160) public sqrtPriceOf;

    Currency internal _synced;

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
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

        if (params.liquidityDelta == 0) {
            // Fee collection path for {plow}: no fees in this mock, so return zeros.
            return (toBalanceDelta(int128(0), int128(0)), toBalanceDelta(int128(0), int128(0)));
        }

        // Seeding path. Decide which side the position is single-sided in by
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
            paid = MockToken(tok).balanceOf(address(this));
        }
    }

    function take(Currency, address, uint256) external pure {
        // No-op: this mock does not track fee accrual, so {plow} will attempt to
        // take zero amounts anyway. The real PoolManager transfers the amounts.
    }

    /// @dev Implements `extsload(bytes32)` so StateLibrary.getSlot0 can read
    ///      back the sqrtPrice we stored during {initialize}. Only the slot
    ///      shape and sqrtPrice bits matter to Unispring.
    function extsload(
        bytes32 /* slot */
    )
        external
        pure
        returns (bytes32)
    {
        return bytes32(0);
    }
}

contract UnispringTest is Test {
    Unispring internal unispring;
    MockPoolManager internal pm;
    MockCoinage internal coinage;

    address internal constant HUB_ADDR = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF;
    address internal constant NEW_TOKEN_ADDR = 0x1111111111111111111111111111111111111111;
    address internal constant LOOKUP_ADDR = 0xd6185883DD1Fa3F6F4F0b646f94D1fb46d618c23;

    uint256 internal constant HUB_SUPPLY = 10_000_000 ether;
    int24 internal constant HUB_TICK_FLOOR = -60_000;

    function setUp() public {
        // 1. Deploy the mock PoolManager and mock the lookup constant.
        pm = new MockPoolManager();
        vm.mockCall(LOOKUP_ADDR, abi.encodeWithSelector(IAddressLookup.value.selector), abi.encode(address(pm)));

        // 2. Deploy a real MockCoinage contract and etch a MockToken at the
        //    fixed HUB address so it has working ERC-20 code.
        coinage = new MockCoinage();
        MockToken template = new MockToken("", "");
        vm.etch(HUB_ADDR, address(template).code);
        coinage.setReturn(HUB_ADDR);

        // 3. Construct Unispring. Its constructor mints the hub token (returning
        //    the etched address) but does not yet touch the PoolManager.
        unispring = new Unispring(address(coinage), "Hub", "HUB", HUB_SUPPLY, bytes32(0), HUB_TICK_FLOOR);

        // 4. Seed the hub pool in a separate call (constructor cannot receive callbacks).
        unispring.seedHub();

        // 5. Etch a second MockToken at the fixed new-token address, below HUB_ADDR,
        //    and point the mock coinage at it for upcoming `make` calls.
        vm.etch(NEW_TOKEN_ADDR, address(template).code);
        coinage.setReturn(NEW_TOKEN_ADDR);
    }

    function test_ConstructorMintsHubAndRegistersImmutables() public view {
        assertEq(unispring.HUB(), HUB_ADDR, "HUB immutable");
        assertEq(address(unispring.LEPTON_PROTO()), address(coinage), "LEPTON_PROTO immutable");
        assertEq(unispring.HUB_SUPPLY(), HUB_SUPPLY, "HUB_SUPPLY immutable");
        assertEq(unispring.HUB_TICK_FLOOR(), HUB_TICK_FLOOR, "HUB_TICK_FLOOR immutable");
    }

    function test_SeedHubRevertsOnDoubleCall() public {
        vm.expectRevert(Unispring.HubAlreadySeeded.selector);
        unispring.seedHub();
    }

    function test_MakeInitializesPoolAndAddsLiquidity() public {
        uint256 supply = 1_000_000 ether;
        int24 tickFloor = -120_000;

        (IERC20 t, PoolId poolId) = unispring.make("Foo", "FOO", supply, tickFloor, bytes32(0));

        // Token registry was populated.
        assertEq(address(t), NEW_TOKEN_ADDR);
        assertEq(address(unispring.token(poolId)), NEW_TOKEN_ADDR);

        // Pool was initialized with the right key shape.
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96, bool seenInit) =
            pm.lastInit();
        assertTrue(seenInit, "initialize not called");
        assertEq(fee, unispring.FEE(), "fee constant mismatch");
        assertEq(tickSpacing, unispring.TICK_SPACING(), "tickSpacing constant mismatch");

        // New token must sort strictly below HUB so it lands as currency0.
        assertLt(uint160(NEW_TOKEN_ADDR), uint160(unispring.HUB()), "newToken must sort below HUB");
        assertEq(Currency.unwrap(currency0), NEW_TOKEN_ADDR);
        assertEq(Currency.unwrap(currency1), unispring.HUB());
        // Single-sided in currency0 → pool price sits at the lower bound (tickFloor).
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickFloor));

        // Liquidity was added with positive delta and the right tick range.
        (, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bool seenModify) = pm.lastModify();
        assertTrue(seenModify, "modifyLiquidity not called");
        assertGt(liquidityDelta, 0, "liquidityDelta must be positive");
        assertEq(tickLower, tickFloor);
        assertEq(tickUpper, TickMath.maxUsableTick(unispring.TICK_SPACING()));

        // The caller settled by transferring new-token to the (mock) PoolManager.
        uint256 pmBalance = MockToken(NEW_TOKEN_ADDR).balanceOf(address(pm));
        uint256 leftover = MockToken(NEW_TOKEN_ADDR).balanceOf(address(unispring));
        assertEq(pmBalance + leftover, supply, "supply must be conserved");
        assertGt(pmBalance, 0, "PoolManager received zero tokens");
    }

    function test_PlowDoesNotRevert() public {
        int24 tickFloor = -120_000;
        unispring.make("Foo", "FOO", 1_000_000 ether, tickFloor, bytes32(0));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(NEW_TOKEN_ADDR),
            currency1: Currency.wrap(HUB_ADDR),
            fee: unispring.FEE(),
            tickSpacing: unispring.TICK_SPACING(),
            hooks: IHooks(address(0))
        });
        int24 tickUpper = TickMath.maxUsableTick(unispring.TICK_SPACING());

        // No fees accrue in this mock, but Unispring holds leftover new-token from
        // the initial seed. The plow function should collect (zero) fees and then
        // deposit the leftover as additional liquidity — without reverting.
        unispring.plow(key, tickFloor, tickUpper);

        // The most recent modifyLiquidity call recorded by the mock was the
        // additive deposit. A positive delta confirms the plow reached the
        // add-liquidity step rather than bailing out at the collect.
        (, int24 lo, int24 up, int256 delta, bool seen) = pm.lastModify();
        assertTrue(seen, "modifyLiquidity not called");
        assertEq(lo, tickFloor);
        assertEq(up, tickUpper);
        assertGt(delta, 0, "plow should have added liquidity from leftover supply");
    }
}
