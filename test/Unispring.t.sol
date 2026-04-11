// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Unispring} from "../src/Unispring.sol";
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
 *         Designed to be `vm.etch`'d at the COINAGE constant address — has no
 *         immutables and reads its only piece of state from storage slot 0.
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
 *         `modifyLiquidity`, `sync`, and `settle`.
 *
 *         Records the call arguments so the test can assert on them, and
 *         performs the bare-minimum settlement bookkeeping needed for the
 *         single-sided seed (pulls the new-token amount from the caller).
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

        // Decide which side the position is single-sided in by inspecting the
        // initialization tick that the test set up. If the pool's price tick
        // sits at the lower bound the position is in currency0; if it sits at
        // the upper bound the position is in currency1. We replicate that here
        // by checking which boundary matches the initialization sqrt price.
        bool isLowerBound = lastInit.sqrtPriceX96 == TickMath.getSqrtPriceAtTick(params.tickLower);

        // Compute the owed amount via the same formulas Unispring used in
        // reverse — but for the mock we just charge an arbitrary value derived
        // from the liquidityDelta. The real PoolManager would compute the
        // exact amount; here all we need is for the caller to settle whatever
        // we report back.
        int128 owed = -int128(uint128(uint256(params.liquidityDelta)));
        callerDelta = isLowerBound ? toBalanceDelta(owed, int128(0)) : toBalanceDelta(int128(0), owed);
        feesAccrued = toBalanceDelta(int128(0), int128(0));
    }

    function sync(Currency currency) external {
        _synced = currency;
    }

    function settle() external payable returns (uint256 paid) {
        // Pull the entire balance the caller pre-funded us with for the synced currency.
        address tok = Currency.unwrap(_synced);
        paid = MockToken(tok).balanceOf(address(this));
    }
}

contract UnispringTest is Test {
    Unispring internal unispring;
    MockPoolManager internal pm;
    MockToken internal newToken;

    function setUp() public {
        unispring = new Unispring();
        pm = new MockPoolManager();

        // Resolve the chain-local PoolManager via the lookup constant.
        vm.mockCall(
            address(unispring.POOL_MANAGER_LOOKUP()),
            abi.encodeWithSelector(IAddressLookup.value.selector),
            abi.encode(address(pm))
        );

        // Etch a no-immutable MockCoinage at the COINAGE constant address.
        MockCoinage mcImpl = new MockCoinage();
        vm.etch(address(unispring.COINAGE()), address(mcImpl).code);

        // Deploy the new token and tell the etched MockCoinage to return it.
        newToken = new MockToken("New", "NEW");
        MockCoinage(address(unispring.COINAGE())).setReturn(address(newToken));

        // Give HUB a non-empty bytecode for completeness.
        vm.etch(unispring.HUB(), hex"00");
    }

    function testMakeCallsCoinageInitializesPoolAndAddsLiquidity() public {
        uint256 supply = 1_000_000 ether;
        int24 tickFloor = -120_000;

        (IERC20 t, PoolId poolId) = unispring.make("Foo", "FOO", supply, tickFloor, bytes32(0));

        // Token registry was populated.
        assertEq(address(t), address(newToken));
        assertEq(address(unispring.token(poolId)), address(newToken));

        // Pool was initialized with the right key shape.
        (Currency currency0, Currency currency1, uint24 fee, int24 tickSpacing, uint160 sqrtPriceX96, bool seenInit) =
            pm.lastInit();
        assertTrue(seenInit, "initialize not called");
        assertEq(fee, unispring.FEE(), "fee constant mismatch");
        assertEq(tickSpacing, unispring.TICK_SPACING(), "tickSpacing constant mismatch");

        // The new token must sort strictly below HUB so it lands as currency0.
        assertLt(uint160(address(newToken)), uint160(unispring.HUB()), "newToken must sort below HUB");
        assertEq(Currency.unwrap(currency0), address(newToken));
        assertEq(Currency.unwrap(currency1), unispring.HUB());
        // Single-sided in currency0 → pool price sits at the lower bound (tickFloor).
        assertEq(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickFloor));

        // Liquidity was added with positive delta and the right tick range.
        (, int24 tickLower, int24 tickUpper, int256 liquidityDelta, bool seenModify) = pm.lastModify();
        assertTrue(seenModify, "modifyLiquidity not called");
        assertGt(liquidityDelta, 0, "liquidityDelta must be positive");
        assertEq(tickLower, tickFloor);
        assertEq(tickUpper, TickMath.maxUsableTick(unispring.TICK_SPACING()));

        // The caller settled by transferring tokens to the (mock) PoolManager.
        // The mock charges `liquidityDelta` units, so the factory should hold the remainder.
        uint256 pmBalance = newToken.balanceOf(address(pm));
        uint256 leftover = newToken.balanceOf(address(unispring));
        assertEq(pmBalance + leftover, supply, "supply must be conserved");
        assertGt(pmBalance, 0, "PoolManager received zero tokens");
    }
}
