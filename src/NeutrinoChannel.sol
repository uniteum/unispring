// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ICoinage} from "icoinage/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IPrototype} from "iproto/IPrototype.sol";
import {Prototype} from "proto/Prototype.sol";

/**
 * @title NeutrinoChannel
 * @notice Per-tick-range mint relay used by NeutrinoSource. A clone
 *         is deployed per `(tickLower, tickUpper)` and acts as the
 *         deployer that calls Coinage's mint; distinct deployers
 *         give distinct minted-token addresses, so each tick range
 *         produces a different token address without consuming
 *         Coinage's salt slot.
 * @dev    Pure factory. After {mint} returns, this contract has no
 *         authority over the minted token. See README §Trust
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
     * @notice Predict the deterministic address of a clone for a sender, tick range, and variant.
     * @param  sender    The address that will call {make}.
     * @param  tickLower Lower tick.
     * @param  tickUpper Upper tick.
     * @param  variant   Salt variant (free for vanity grinding).
     * @return exists True if the clone is already deployed.
     * @return home   The deterministic clone address.
     * @return salt   The CREATE2 salt.
     */
    function made(address sender, int24 tickLower, int24 tickUpper, uint256 variant)
        external
        view
        returns (bool exists, address home, bytes32 salt)
    {
        (exists, home, salt) = this.made(encode(sender, tickLower, tickUpper), variant);
    }

    /**
     * @notice Deploy a clone for the caller's tick range and variant. Idempotent.
     * @param  tickLower Lower tick.
     * @param  tickUpper Upper tick.
     * @param  variant   Salt variant (free for vanity grinding).
     * @return clone The deployed (or existing) clone.
     */
    function make(int24 tickLower, int24 tickUpper, uint256 variant) external returns (NeutrinoChannel clone) {
        (, address home,) = this.make(encode(msg.sender, tickLower, tickUpper), variant);
        clone = NeutrinoChannel(home);
    }

    /**
     * @inheritdoc IPrototype
     * @dev Decodes `(sender, tickLower, tickUpper)` and assigns `sender` to {source}.
     *      The ticks shape the salt but are not stored.
     */
    function zzInit(bytes calldata args, uint256) external override onlyProto {
        (address sender,,) = abi.decode(args, (address, int24, int24));
        source = sender;
    }
}
