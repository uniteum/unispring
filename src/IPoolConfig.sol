// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

/**
 * @title IPoolConfig
 * @notice Read-only view of a pool's parameters — the values needed to
 *         construct a {PoolKey} or read pool state from the
 *         {PoolManager}. Typically used by off-chain scripts.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IPoolConfig {
    /**
     * @notice Pool fee in hundredths of a bip (0.01%).
     */
    function fee() external view returns (uint24);

    /**
     * @notice Pool tick spacing.
     */
    function tickSpacing() external view returns (int24);

    /**
     * @notice The Uniswap V4 PoolManager.
     */
    function poolManager() external view returns (IPoolManager);
}
