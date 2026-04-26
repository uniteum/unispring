// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title IFountainPoolConfig
 * @notice Read-only view of a Fountain's pool parameters — the values
 *         needed to construct a {PoolKey} or read pool state from the
 *         {PoolManager}. Typically used by off-chain scripts.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IFountainPoolConfig {
    /**
     * @notice Pool fee in hundredths of a bip (0.01%).
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function FEE() external view returns (uint24);

    /**
     * @notice Pool tick spacing.
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function TICK_SPACING() external view returns (int24);

    /**
     * @notice The Uniswap V4 PoolManager.
     */
    // forge-lint: disable-next-line(mixed-case-function)
    function poolManager() external view returns (IPoolManager);
}
