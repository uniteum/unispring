// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @dev Record of a single seated liquidity position in a Fountain. The
 *      registry of these is the data structure {IFountainTaker} operates
 *      on.
 */
struct Position {
    PoolKey key;
    int24 tickLower;
    int24 tickUpper;
}

/**
 * @title IFountainTaker
 * @notice Surface for callers that work with seated positions and the
 *         fees they accrue: enumerate the registry, forecast pending
 *         fees, and claim them. Centered on {take} as the operational
 *         verb; the registry-view methods exist to support it.
 * @dev    The "Taker" role here means *fee taker*. This overrides the
 *         broader DeFi convention where "taker" usually means liquidity
 *         taker (the maker/taker pair). In this codebase {take} is firmly
 *         fee-claiming.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IFountainTaker {
    /**
     * @notice Emitted when {take} pulls fees for one position into Fountain.
     * @param  positionId The id of the position whose fees were taken.
     * @param  poolId     The Uniswap V4 pool the position belongs to.
     * @param  amount0    Fees taken on the pool's currency0.
     * @param  amount1    Fees taken on the pool's currency1.
     */
    event Taken(uint256 indexed positionId, PoolId indexed poolId, uint256 amount0, uint256 amount1);

    /**
     * @notice Thrown when a take or untaken call references a position
     *         id that does not exist.
     */
    error UnknownPosition(uint256 positionId);

    /**
     * @notice The number of seated positions.
     */
    function positionsCount() external view returns (uint256);

    /**
     * @notice Return a contiguous slice of the position registry. Clamps
     *         to the array bounds: `offset` at or past the end returns
     *         an empty array; `count` running past the end returns only
     *         the existing tail.
     */
    function positionsSlice(uint256 offset, uint256 count) external view returns (Position[] memory slice);

    /**
     * @notice Return untaken swap fees for each referenced position.
     *         Values match what {take} would transfer if called now.
     *         Amounts are ordered by each position's pool currencies:
     *         `amounts0[i]` is for position `ids[i]`'s `currency0`.
     * @param  ids Position ids to query. Reverts on any out-of-range id.
     */
    function untaken(uint256[] calldata ids)
        external
        view
        returns (uint256[] memory amounts0, uint256[] memory amounts1);

    /**
     * @notice Take accrued swap fees for a single position.
     */
    function take(uint256 positionId) external;

    /**
     * @notice Take accrued swap fees for several positions in a single
     *         unlock. Reverts with {UnknownPosition} if any id is out
     *         of range.
     */
    function take(uint256[] calldata ids) external;
}
