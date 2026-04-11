// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Script, console2} from "forge-std/Script.sol";

/**
 * @notice Minimal V4 swap helper. Deploys once (CREATE2 via Nick's factory is
 *         not required since this contract has no state), then {bootstrap} is
 *         called with an ETH value to execute a tiny `ETH → HUB` swap.
 * @dev    The swap crosses the hub pool's upper tick downward, activating the
 *         mirror-case single-sided position so that `getLiquidity(poolId) > 0`
 *         for all subsequent quoter/UI queries. The received HUB tokens stay
 *         with `caller` — whoever triggered the bootstrap.
 */
contract HubBootstrapper is IUnlockCallback {
    IPoolManager public immutable POOL_MANAGER;

    error InvalidUnlockCaller();

    struct Call {
        PoolKey key;
        address payer;
        address recipient;
        uint256 amountIn;
    }

    constructor(IPoolManager poolManager) {
        POOL_MANAGER = poolManager;
    }

    /**
     * @notice Execute an ETH → HUB exact-input swap through the given pool.
     * @dev Send ETH with the call equal to `amountIn`. Received HUB is forwarded
     *      to `recipient`.
     */
    function bootstrap(PoolKey calldata key, address recipient, uint256 amountIn) external payable {
        require(msg.value == amountIn, "value mismatch");
        POOL_MANAGER.unlock(abi.encode(Call({key: key, payer: msg.sender, recipient: recipient, amountIn: amountIn})));
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert InvalidUnlockCaller();
        Call memory c = abi.decode(data, (Call));

        // zeroForOne: selling currency0 (ETH) for currency1 (HUB). Exact input is
        // a negative amountSpecified. Price limit at the minimum allowed.
        BalanceDelta delta = POOL_MANAGER.swap(
            c.key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(c.amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        // We owe currency0 (ETH) and are owed currency1 (HUB).
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        // Pay ETH.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 paid = uint256(uint128(-amount0));
        POOL_MANAGER.settle{value: paid}();

        // Take HUB out to the recipient.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 received = uint256(uint128(amount1));
        POOL_MANAGER.take(c.key.currency1, c.recipient, received);

        return "";
    }
}

/**
 * @notice Deploy-or-reuse the bootstrapper and perform a single tiny ETH → HUB
 *         swap against an already-deployed Unispring instance. Flips the hub
 *         pool from the inactive-at-spot mirror state into a normal active
 *         state that hosted Uniswap front-ends will quote against.
 * @dev    Env vars:
 *           Unispring       — deployed Unispring address (required)
 *           Bootstrapper    — an already-deployed HubBootstrapper (optional); if
 *                             omitted, a fresh one is deployed.
 *           BootstrapValue  — wei of ETH to swap, default 1 gwei (1e9).
 *           Recipient       — who receives the swapped HUB, default msg.sender.
 *
 *         Usage: forge script script/BootstrapHub.s.sol:BootstrapHub -f $chain \
 *                    --private-key $tx_key --broadcast
 */
contract BootstrapHub is Script {
    function run() external {
        Unispring unispring = Unispring(payable(vm.envAddress("Unispring")));
        uint256 amountIn = vm.envOr("BootstrapValue", uint256(1 gwei));
        address recipient = vm.envOr("Recipient", msg.sender);
        address existing = vm.envOr("Bootstrapper", address(0));

        IPoolManager pm = unispring.POOL_MANAGER();

        // Reconstruct the hub pool key from Unispring's constants and immutables.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(unispring.HUB()),
            fee: unispring.FEE(),
            tickSpacing: unispring.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        HubBootstrapper bs;
        if (existing == address(0)) {
            vm.startBroadcast();
            bs = new HubBootstrapper(pm);
            vm.stopBroadcast();
            console2.log("deployed HubBootstrapper:", address(bs));
        } else {
            bs = HubBootstrapper(existing);
            console2.log("using HubBootstrapper    :", existing);
        }

        console2.log("hub pool id     :", uint256(PoolId.unwrap(unispring.hubPool())));
        console2.log("bootstrap value :", amountIn);
        console2.log("recipient       :", recipient);

        vm.startBroadcast();
        bs.bootstrap{value: amountIn}(key, recipient, amountIn);
        vm.stopBroadcast();

        console2.log("bootstrap complete - hub pool should now be active at spot");
    }
}
