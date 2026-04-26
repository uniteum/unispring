// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";

/**
 * @title NeutrinoChannel
 * @notice Lightweight relay cloned per tick range so that each (tickLower,
 *         tickUpper) pair produces a distinct Coinage deployer address — and
 *         therefore a distinct minted-token address — without consuming the
 *         coinage salt. The minted tokens are neutrinos — fair-launched
 *         (neutral) leptons.
 * @dev    Pure factory. Once {mint} returns, this contract has no further
 *         authority over the minted token — all post-mint behavior is
 *         governed by the lepton ERC-20 implementation. See README §Trust
 *         boundaries.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract NeutrinoChannel {
    string public constant VERSION = "0.1.0";

    /**
     * @notice The prototype instance. On clones, this points back to the
     *         original deployment.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    NeutrinoChannel public immutable proto;

    /**
     * @notice The address that created this clone by calling {make}, and the
     *         only address authorized to call {mint} on it. Set once by
     *         {zzInit} during {make}.
     */
    address public source;

    /**
     * @notice Thrown when {zzInit} is called by anyone other than {proto},
     *         or when {mint} is called by anyone other than {source}.
     */
    error Unauthorized();

    constructor() {
        proto = this;
    }

    // ---- Bitsy factory ----

    /**
     * @notice Predict the deterministic address of a clone for a sender and tick range.
     * @param sender    The address that will call {make}.
     * @param tickLower Lower tick.
     * @param tickUpper Upper tick.
     * @return exists True if the clone is already deployed.
     * @return home   The deterministic clone address.
     * @return salt   The CREATE2 salt (derived from sender and tick range).
     */
    function made(address sender, int24 tickLower, int24 tickUpper)
        public
        view
        returns (bool exists, address home, bytes32 salt)
    {
        salt = keccak256(abi.encode(sender, tickLower, tickUpper));
        home = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy a clone for the caller's tick range. Idempotent.
     * @param tickLower Lower tick.
     * @param tickUpper Upper tick.
     * @return clone The deployed (or existing) clone.
     */
    function make(int24 tickLower, int24 tickUpper) external returns (NeutrinoChannel clone) {
        (bool exists, address home, bytes32 salt) = made(msg.sender, tickLower, tickUpper);
        clone = NeutrinoChannel(home);
        if (!exists) {
            Clones.cloneDeterministic(address(proto), salt, 0);
            clone.zzInit(msg.sender);
        }
    }

    /**
     * @notice Initializer called by {proto} on a freshly deployed clone.
     *         Sets {source} to the address that called {make}. Reverts with
     *         {Unauthorized} if called by anyone other than {proto}.
     */
    function zzInit(address source_) external {
        if (msg.sender != address(proto)) revert Unauthorized();
        source = source_;
    }

    // ---- Relay ----

    /**
     * @notice Mint a token via the Coinage factory and transfer the entire
     *         supply to the caller. Because each clone has a tick-dependent
     *         address, Coinage sees a different deployer per tick range.
     *         Only {source} may call.
     * @param coinage  Coinage prototype to mint through.
     * @param name     Token name.
     * @param symbol   Token symbol.
     * @param decimals Token decimals.
     * @param supply   Token supply, denominated in the smallest unit.
     * @param salt     Coinage salt (free for vanity grinding).
     * @return token The minted token.
     */
    function mint(
        ICoinage coinage,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        bytes32 salt
    ) external returns (IERC20Metadata token) {
        if (msg.sender != source) revert Unauthorized();
        token = coinage.make(name, symbol, decimals, supply, salt);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(msg.sender, supply);
    }
}
