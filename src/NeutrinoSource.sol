// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {NeutrinoChannel} from "./NeutrinoChannel.sol";
import {Unispring} from "./Unispring.sol";

/**
 * @title NeutrinoSource
 * @notice One-click fair-launch factory. A NeutrinoSource clone bundles a hub
 *         token minted via Coinage with a Unispring clone. Call {launch} on a
 *         clone to create a spoke token whose entire supply is deposited as
 *         permanent liquidity, paired against the hub. The minted tokens are
 *         neutrinos — fair-launched (neutral) leptons.
 * @dev    Pure factory. Once {launch} returns, this contract has no further
 *         authority over the spoke token or its pool: no pause, no reclaim,
 *         no fee knob. Post-launch token behavior is governed by the minted
 *         ERC-20 (lepton); pool behavior by the Uniswap V4 PoolManager and
 *         whatever DEX routers reach it. See README §Trust boundaries.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract NeutrinoSource {
    string public constant VERSION = "0.1.0";

    /**
     * @notice The prototype instance that acts as the Bitsy factory.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    NeutrinoSource public immutable proto;

    /**
     * @notice The Unispring prototype used to create fair-launch pools.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Unispring public immutable springProto;

    /**
     * @notice The NeutrinoChannel prototype cloned per tick range so each range
     *         produces a distinct Coinage deployer — and therefore a distinct
     *         minted-token address — for both hubs (minted by {make}) and
     *         spokes (minted by {launch}).
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    NeutrinoChannel public immutable channelProto;

    /**
     * @notice The Coinage prototype used to create hub and spoke tokens.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    ICoinage public immutable coinage;

    /**
     * @notice The Unispring clone for this clone's hub token, set by {zzInit}.
     */
    Unispring public spring;

    /**
     * @notice The hub token for this clone, derived from {spring}.
     */
    function hub() public view returns (IERC20Metadata) {
        return IERC20Metadata(spring.hub());
    }

    /**
     * @notice Emitted when a new clone is created via {make}.
     */
    event Make(NeutrinoSource indexed clone, IERC20Metadata indexed hub, Unispring indexed spring);

    /**
     * @notice Emitted when a spoke token is launched via {launch}.
     */
    event Launch(IERC20Metadata indexed token, uint256 supply, int24 tickLower, int24 tickUpper);

    /**
     * @notice Thrown when {zzInit} is called by anyone other than {proto}.
     */
    error Unauthorized();

    /**
     * @notice Construct the prototype.
     * @param unispring The Unispring prototype.
     * @param channel   The NeutrinoChannel prototype.
     * @param minter   The Coinage prototype.
     */
    constructor(Unispring unispring, NeutrinoChannel channel, ICoinage minter) {
        proto = this;
        springProto = unispring;
        channelProto = channel;
        coinage = minter;
    }

    // ---- Bitsy factory ----

    /**
     * @notice Predict the deterministic address of a clone.
     * @param name      Hub token name (passed to Coinage).
     * @param symbol    Hub token symbol (passed to Coinage).
     * @param decimals  Hub token decimals (passed to Coinage).
     * @param supply    Hub token supply (passed to Coinage).
     * @param tickLower Lower tick for the hub's ETH pool.
     * @param tickUpper Upper tick for the hub's ETH pool.
     * @param tokenSalt Salt for the Coinage hub token.
     * @return exists   True if the clone is already deployed.
     * @return home     The deterministic clone address.
     * @return salt     The CREATE2 salt (derived from the input parameters).
     * @return hubHome  The deterministic hub token address.
     */
    function made(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        bytes32 tokenSalt
    ) public view returns (bool exists, address home, bytes32 salt, address hubHome) {
        salt = keccak256(abi.encode(name, symbol, decimals, supply, tickLower, tickUpper, tokenSalt));
        home = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        exists = home.code.length > 0;
        (, address channel,) = channelProto.made(address(proto), tickLower, tickUpper);
        (, hubHome,) = coinage.made(channel, name, symbol, decimals, supply, tokenSalt);
    }

    /**
     * @notice Create a hub token, a Unispring clone for it, and a
     *         NeutrinoSource clone that bundles them together. Idempotent.
     * @param name      Hub token name.
     * @param symbol    Hub token symbol.
     * @param decimals  Hub token decimals.
     * @param supply    Hub token supply (entire supply funds the ETH/hub pool).
     * @param tickLower Lower tick for the hub's ETH pool.
     * @param tickUpper Upper tick for the hub's ETH pool.
     * @param tokenSalt Salt for the Coinage hub token.
     * @return clone The deployed (or existing) NeutrinoSource clone.
     */
    function make(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        bytes32 tokenSalt
    ) external returns (NeutrinoSource clone) {
        if (this != proto) {
            clone = proto.make(name, symbol, decimals, supply, tickLower, tickUpper, tokenSalt);
        } else {
            (bool exists, address home, bytes32 salt,) =
                made(name, symbol, decimals, supply, tickLower, tickUpper, tokenSalt);
            clone = NeutrinoSource(home);
            if (!exists) {
                NeutrinoChannel hubChannel = channelProto.make(tickLower, tickUpper);
                IERC20Metadata hubToken = hubChannel.mint(coinage, name, symbol, decimals, supply, tokenSalt);

                (, address springHome,) = springProto.made(hubToken, tickLower, tickUpper);
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20Metadata(address(hubToken)).transfer(springHome, supply);
                Unispring unispring = springProto.make(hubToken, tickLower, tickUpper);

                Clones.cloneDeterministic(address(proto), salt, 0);
                NeutrinoSource(home).zzInit(unispring);
                emit Make(clone, IERC20Metadata(address(hubToken)), unispring);
            }
        }
    }

    /**
     * @notice Initializer called by {proto} on a freshly deployed clone.
     * @param spring_ The Unispring clone for this NeutrinoSource's hub token.
     */
    function zzInit(Unispring spring_) external {
        if (msg.sender != address(proto)) revert Unauthorized();
        spring = spring_;
    }

    // ---- Fair launch ----

    /**
     * @notice Create a spoke token via Coinage and deposit its entire supply as
     *         permanent liquidity on this clone's Unispring, paired against the
     *         hub. Permissionless — anyone can launch a spoke.
     * @param name      Spoke token name.
     * @param symbol    Spoke token symbol.
     * @param decimals  Spoke token decimals.
     * @param supply    Spoke token supply (entire supply is funded).
     * @param salt      Salt for the Coinage spoke token.
     * @param tickLower Lower tick (price floor in spoke-in-hub terms).
     * @param tickUpper Upper tick (price ceiling in spoke-in-hub terms).
     * @return token The newly created spoke token.
     */
    function launch(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        bytes32 salt,
        int24 tickLower,
        int24 tickUpper
    ) external returns (IERC20Metadata token) {
        NeutrinoChannel channel = channelProto.make(tickLower, tickUpper);
        token = channel.mint(coinage, name, symbol, decimals, supply, salt);
        token.approve(address(spring), supply);
        spring.offer(Currency.wrap(address(token)), supply, tickLower, tickUpper);
        emit Launch(token, supply, tickLower, tickUpper);
    }
}
