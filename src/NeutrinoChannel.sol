// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ICoinage} from "icoinage/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IPrototype} from "iproto/IPrototype.sol";
import {Prototype} from "proto/Prototype.sol";

/**
 * @title NeutrinoChannel
 * @notice Lightweight relay cloned per tick range so that each (tickLower,
 *         tickUpper) pair produces a distinct Coinage deployer address — and
 *         therefore a distinct minted-token address — without consuming the
 *         minter salt. The minted tokens are neutrinos — fair-launched
 *         (neutral) leptons.
 * @dev    Pure factory. Once {mint} returns, this contract has no further
 *         authority over the minted token — all post-mint behavior is
 *         governed by the lepton ERC-20 implementation. See README §Trust
 *         boundaries.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract NeutrinoChannel is Prototype {
    string public constant version = "0.7.0";

    /**
     * @notice The address that created this clone by calling {make}, and the
     *         only address authorized to call {mint} on it. Set once by
     *         {zzInit} during {make}.
     */
    address public source;

    // ---- Relay ----

    /**
     * @notice Mint a token via the Coinage factory and transfer the entire
     *         supply to the caller. Because each clone has a tick-dependent
     *         address, Coinage sees a different deployer per tick range.
     *         Only {source} may call.
     * @param  minter   Coinage prototype to mint through.
     * @param  name     Token name.
     * @param  symbol   Token symbol.
     * @param  decimals Token decimals.
     * @param  supply   Token supply, denominated in the smallest unit.
     * @param  salt     Coinage variant (free for vanity grinding).
     * @return token    The minted token.
     */
    function mint(
        ICoinage minter,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        uint256 salt
    ) external returns (IERC20Metadata token) {
        if (msg.sender != source) revert Unauthorized();
        token = minter.make(name, symbol, decimals, supply, salt);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.transfer(msg.sender, supply);
    }

    // ---- Bitsy factory ----

    /**
     * @notice ABI-encode the per-clone init args.
     * @dev    The returned bytes are the canonical args passed to
     *         {Prototype.make} and {zzInit}. `tickLower` and `tickUpper` are
     *         baked into the salt to give each tick range a distinct clone
     *         address; only `sender` is stored at init time (as {source}).
     */
    function encode(address sender, int24 tickLower, int24 tickUpper) public pure returns (bytes memory args) {
        args = abi.encode(sender, tickLower, tickUpper);
    }

    /**
     * @notice Predict the deterministic address of a clone for a sender and tick range.
     * @param  sender    The address that will call {make}.
     * @param  tickLower Lower tick.
     * @param  tickUpper Upper tick.
     * @return exists True if the clone is already deployed.
     * @return home   The deterministic clone address.
     * @return salt   The CREATE2 salt.
     */
    function made(address sender, int24 tickLower, int24 tickUpper)
        external
        view
        returns (bool exists, address home, bytes32 salt)
    {
        (exists, home, salt) = this.made(encode(sender, tickLower, tickUpper), 0);
    }

    /**
     * @notice Deploy a clone for the caller's tick range. Idempotent.
     * @param  tickLower Lower tick.
     * @param  tickUpper Upper tick.
     * @return clone The deployed (or existing) clone.
     */
    function make(int24 tickLower, int24 tickUpper) external returns (NeutrinoChannel clone) {
        (, address home,) = this.make(encode(msg.sender, tickLower, tickUpper), 0);
        clone = NeutrinoChannel(home);
    }

    /**
     * @inheritdoc IPrototype
     * @dev Decodes `(sender, tickLower, tickUpper)` and assigns `sender` to {source}.
     *      The ticks shape the salt but are not stored.
     */
    function zzInit(
        bytes calldata args,
        uint256 /*variant*/
    )
        public
        override
        onlyProto
    {
        (address sender,,) = abi.decode(args, (address, int24, int24));
        source = sender;
    }
}
