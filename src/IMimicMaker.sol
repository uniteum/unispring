// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IMimicMaker
 * @notice Clone-factory surface of Mimicry. One clone exists per
 *         `(original, symbol)` pair, deployed via CREATE2; {made}
 *         predicts the address without deploying. Lets callers depend
 *         on the factory without pulling in V4 imports.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IMimicMaker {
    /**
     * @notice Emitted when {make} deploys a new clone.
     * @param  clone    The clone's deterministic CREATE2 address.
     * @param  original The reference token the clone's mimics are pegged
     *                  against (`address(0)` for native ETH).
     * @param  symbol   The shared symbol every mimic minted by the clone
     *                  carries.
     */
    event Make(address indexed clone, address indexed original, string symbol);

    /**
     * @notice Thrown when an initializer is invoked by anyone other
     *         than the prototype.
     */
    error Unauthorized();

    /**
     * @notice Predict the deterministic clone address for
     *         `(original, symbol)`.
     * @return exists True if the clone is already deployed.
     * @return home   The deterministic clone address.
     * @return salt   The CREATE2 salt.
     */
    function made(address original, string calldata symbol)
        external
        view
        returns (bool exists, address home, bytes32 salt);

    /**
     * @notice Deploy (or return) the clone for `(original, symbol)`.
     *         Idempotent — repeated calls return the same address.
     * @return clone The deployed (or existing) clone address.
     */
    function make(address original, string calldata symbol) external returns (address clone);
}
