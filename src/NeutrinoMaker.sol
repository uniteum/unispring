// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";

/**
 * @title NeutrinoMaker
 * @notice Lightweight relay cloned per tick range so that each (tickLower,
 *         tickUpper) pair produces a distinct Lepton deployer address — and
 *         therefore a distinct hub token — without consuming the lepton salt.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract NeutrinoMaker {
    /**
     * @notice The prototype instance that acts as the Bitsy factory.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    NeutrinoMaker public immutable PROTO;

    /**
     * @notice The Lepton prototype used to mint hub tokens.
     */
    ICoinage public immutable LEPTON;

    /**
     * @param lepton The Lepton prototype (ICoinage).
     */
    constructor(ICoinage lepton) {
        PROTO = this;
        LEPTON = lepton;
    }

    // ---- Bitsy factory ----

    /**
     * @notice Predict the deterministic address of a clone for a tick range.
     * @param tickLower Lower tick.
     * @param tickUpper Upper tick.
     * @return exists True if the clone is already deployed.
     * @return home   The deterministic clone address.
     * @return salt   The CREATE2 salt (derived from the tick range).
     */
    function made(int24 tickLower, int24 tickUpper)
        public
        view
        returns (bool exists, address home, bytes32 salt)
    {
        salt = keccak256(abi.encode(tickLower, tickUpper));
        home = Clones.predictDeterministicAddress(address(PROTO), salt, address(PROTO));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy a clone for the given tick range. Idempotent.
     * @param tickLower Lower tick.
     * @param tickUpper Upper tick.
     * @return clone The deployed (or existing) clone.
     */
    function make(int24 tickLower, int24 tickUpper) external returns (NeutrinoMaker clone) {
        (bool exists, address home, bytes32 salt) = made(tickLower, tickUpper);
        clone = NeutrinoMaker(home);
        if (!exists) {
            Clones.cloneDeterministic(address(PROTO), salt);
        }
    }

    // ---- Relay ----

    /**
     * @notice Mint a hub token via Lepton and transfer the entire supply to the
     *         caller. Because each clone has a tick-dependent address, Lepton
     *         sees a different deployer per tick range.
     * @param name   Token name.
     * @param symbol Token symbol.
     * @param supply Token supply.
     * @param salt   Lepton salt (free for vanity grinding).
     * @return token The minted hub token.
     */
    function mint(string calldata name, string calldata symbol, uint256 supply, bytes32 salt)
        external
        returns (ICoinage token)
    {
        token = LEPTON.make(name, symbol, supply, salt);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(address(token)).transfer(msg.sender, supply);
    }
}
