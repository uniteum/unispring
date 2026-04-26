// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IFountainPoolConfig} from "../src/IFountainPoolConfig.sol";
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
 * @notice Read-only: simulate an ETH → HUB swap against V4Quoter on Sepolia.
 *         Returns 0 / reverts while the hub pool is still in the mirror-case
 *         inactive-at-spot state; returns a real quote once the first
 *         ETH → HUB swap has crossed the upper tick.
 * @dev    Usage: forge script script/QuoteHub.s.sol -f $chain
 *
 *         Env vars required:
 *           Unispring — Unispring factory address
 */
contract QuoteHub is Script {
    IV4Quoter constant QUOTER = IV4Quoter(0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227);

    function run() external {
        Unispring unispring = Unispring(payable(vm.envAddress("Unispring")));
        IFountainPoolConfig fountain = IFountainPoolConfig(address(unispring.FOUNTAIN()));

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(unispring.hub()),
            fee: fountain.FEE(),
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        uint128 exactAmount = 1 gwei;
        IV4Quoter.QuoteExactSingleParams memory params =
            IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: true, exactAmount: exactAmount, hookData: ""});

        (uint256 amountOut, uint256 gasEstimate) = QUOTER.quoteExactInputSingle(params);

        console.log("ETH in:       ", uint256(exactAmount));
        console.log("HUB out:      ", amountOut);
        console.log("gas estimate: ", gasEstimate);
    }
}
