// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @dev Record of a single seated liquidity position in a pool. The
 *      registry of these is the data structure {IFeeTaker} operates
 *      on.
 */
struct Position {
    /**
     * @notice The lower currency of the pool, sorted numerically
     */
    address currency0;
    /**
     * @notice The higher currency of the pool, sorted numerically
     */
    address currency1;
    /**
     * @notice The pool LP fee, capped at 1_000_000. If the highest bit is 1, the pool has a dynamic
     *         fee and must be exactly equal to 0x800000.
     */
    uint24 fee;
    /**
     * @notice Ticks that involve positions must be a multiple of tick spacing.
     */
    int24 tickSpacing;
    /**
     * @notice The lower bound of the position's tick range, inclusive.
     */
    int24 tickLower;
    /**
     * @notice The upper bound of the position's tick range, exclusive.
     */
    int24 tickUpper;
}

/**
 * @title IFeeTaker
 * @notice Surface for callers that work with seated positions and the
 *         fees they accrue: enumerate the registry, forecast pending
 *         fees, and claim them. Centered on {take} as the operational
 *         verb; the registry-view methods exist to support it.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IFeeTaker {
    /**
     * @notice Emitted when {take} pulls fees for one position.
     * @param  positionId The id of the position whose fees were taken.
     * @param  amount0    Fees taken on the pool's currency0.
     * @param  amount1    Fees taken on the pool's currency1.
     */
    event Taken(uint256 indexed positionId, uint256 amount0, uint256 amount1);

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
     * @notice Take accrued swap fees for several positions in a single
     *         unlock. Reverts with {UnknownPosition} if any id is out
     *         of range.
     */
    function take(uint256[] calldata ids) external;
}
