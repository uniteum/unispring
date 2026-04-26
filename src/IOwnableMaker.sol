// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title IOwnableMaker
 * @notice Shape of an "ownable clone" factory: one clone per
 *         `(msg.sender, variant)` pair, the produced clone is `Ownable`
 *         and its owner is the caller of {make}. {made} predicts the
 *         deterministic CREATE2 address without deploying. The pattern
 *         names the role rather than any specific contract; callers
 *         that want to interact with any ownable-maker through a
 *         common shape cast the address to this interface.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IOwnableMaker {
    /**
     * @notice Predict the deterministic clone address for
     *         `(owner, variant)` without deploying.
     * @param  owner   The address that would own the clone.
     * @param  variant Discriminator letting one owner hold multiple clones.
     * @return exists  True iff the clone has already been deployed.
     * @return home    The predicted (or actual, if `exists`) clone address.
     * @return salt    The CREATE2 salt used for the clone.
     */
    function made(address owner, uint256 variant) external view returns (bool exists, address home, bytes32 salt);

    /**
     * @notice Deploy (or return) the clone owned by `msg.sender` under
     *         `variant`. One clone exists per `(msg.sender, variant)`
     *         pair; repeated calls return the same address.
     * @param  variant  Discriminator letting one owner hold multiple clones.
     * @return instance The clone address. Callers cast to the concrete
     *                  contract type when they need its full surface.
     */
    function make(uint256 variant) external returns (address instance);
}
