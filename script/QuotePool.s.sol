// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Unispring} from "../src/Unispring.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Script, console} from "forge-std/Script.sol";

/**
 * @notice Minimal V4Quoter interface — just the single-hop exact-input entrypoint.
 */
interface IV4Quoter {
    struct QuoteExactSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 exactAmount;
        bytes hookData;
    }

    function quoteExactInputSingle(QuoteExactSingleParams calldata params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/**
 * @notice Read-only: simulate a HUB → newToken swap directly against the V4Quoter
 *         on Sepolia, bypassing the hosted Uniswap interface entirely.
 * @dev    Usage: forge script script/QuotePool.s.sol -f $chain
 *
 *         Env vars required:
 *           Unispring   — Unispring factory address
 *           HelloWorld  — new token address
 */
contract QuotePool is Script {
    // Uniswap v4 Quoter on Ethereum Sepolia.
    IV4Quoter constant QUOTER = IV4Quoter(0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227);

    function run() external {
        Unispring unispring = Unispring(payable(vm.envAddress("Unispring")));
        address newToken = vm.envAddress("HelloWorld");
        address hub = unispring.hub();
        uint128 hubAmount = uint128(vm.envUint("HubAmount"));

        // Case-1 invariant: new token is currency0, HUB is currency1.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(newToken),
            currency1: Currency.wrap(hub),
            fee: unispring.FOUNTAIN().FEE(),
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        // Sell HUB (currency1) to receive new token (currency0) → oneForZero.
        IV4Quoter.QuoteExactSingleParams memory params =
            IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: false, exactAmount: hubAmount, hookData: ""});

        (uint256 amountOut, uint256 gasEstimate) = QUOTER.quoteExactInputSingle(params);

        console.log("HUB in:       ", uint256(hubAmount));
        console.log("newToken out: ", amountOut);
        console.log("gas estimate: ", gasEstimate);
    }
}
