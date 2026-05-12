// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {ICoinage} from "icoinage/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IPrototype} from "iproto/IPrototype.sol";
import {Prototype} from "proto/Prototype.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {NeutrinoChannel} from "./NeutrinoChannel.sol";
import {Manifold} from "./Manifold.sol";

/**
 * @title NeutrinoSource
 * @notice One-click fair-launch factory. A NeutrinoSource clone bundles a hub
 *         token minted via Coinage with a Manifold clone. Call {launch} on a
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
contract NeutrinoSource is Prototype {
    string public constant version = "0.7.0";

    /**
     * @notice The Manifold prototype used to create fair-launch pools.
     */
    Manifold public immutable springProto;

    /**
     * @notice The NeutrinoChannel prototype cloned per tick range so each range
     *         produces a distinct Coinage deployer — and therefore a distinct
     *         minted-token address — for both hubs (minted by {make}) and
     *         spokes (minted by {launch}).
     */
    NeutrinoChannel public immutable channelProto;

    /**
     * @notice The Coinage prototype used to create hub and spoke tokens.
     */
    ICoinage public immutable coinage;

    /**
     * @notice The Manifold clone for this clone's hub token, set by {zzInit}.
     */
    Manifold public spring;

    /**
     * @notice The hub token for this clone, derived from {spring}.
     */
    function hub() public view returns (IERC20Metadata) {
        return IERC20Metadata(spring.hub());
    }

    /**
     * @notice Emitted when a new clone is created via {make}.
     */
    event Make(NeutrinoSource indexed clone, IERC20Metadata indexed hub, Manifold indexed spring);

    /**
     * @notice Emitted when a spoke token is launched via {launch}.
     */
    event Launch(IERC20Metadata indexed token, uint256 supply, int24 tickLower, int24 tickUpper);

    /**
     * @notice Construct the prototype.
     * @param manifold The Manifold prototype.
     * @param channel  The NeutrinoChannel prototype.
     * @param minter   The Coinage prototype.
     */
    constructor(Manifold manifold, NeutrinoChannel channel, ICoinage minter) {
        springProto = manifold;
        channelProto = channel;
        coinage = minter;
    }

    // ---- Fair launch ----

    /**
     * @notice Create a spoke token via Coinage and deposit its entire supply as
     *         permanent liquidity on this clone's Manifold, paired against the
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
        uint256 salt,
        int24 tickLower,
        int24 tickUpper
    ) external returns (IERC20Metadata token) {
        NeutrinoChannel channel = channelProto.make(tickLower, tickUpper, 0);
        token = channel.mint(coinage, name, symbol, decimals, supply, salt);
        token.approve(address(spring), supply);
        spring.offer(Currency.wrap(address(token)), supply, tickLower, tickUpper);
        emit Launch(token, supply, tickLower, tickUpper);
    }

    // ---- Bitsy factory ----

    /**
     * @notice ABI-encode the per-clone init args.
     * @dev    The returned bytes are the canonical args passed to
     *         {Prototype.make} and {zzInit}.
     */
    function encode(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenSalt
    ) public pure returns (bytes memory args) {
        args = abi.encode(name, symbol, decimals, supply, tickLower, tickUpper, tokenSalt);
    }

    /**
     * @notice Predict the deterministic address of a clone and its hub token.
     * @param  name      Hub token name (passed to Coinage).
     * @param  symbol    Hub token symbol (passed to Coinage).
     * @param  decimals  Hub token decimals (passed to Coinage).
     * @param  supply    Hub token supply (passed to Coinage).
     * @param  tickLower Lower tick for the hub's ETH pool.
     * @param  tickUpper Upper tick for the hub's ETH pool.
     * @param  tokenSalt Salt for the Coinage hub token.
     * @param  variant   Salt variant (free for vanity grinding).
     * @return exists  True if the clone is already deployed.
     * @return home    The deterministic clone address.
     * @return salt    The CREATE2 salt.
     * @return hubHome The deterministic hub token address.
     */
    function made(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenSalt,
        uint256 variant
    ) external view returns (bool exists, address home, bytes32 salt, address hubHome) {
        (exists, home, salt) =
            this.made(encode(name, symbol, decimals, supply, tickLower, tickUpper, tokenSalt), variant);
        (, address channel,) = channelProto.made(proto, tickLower, tickUpper, 0);
        (, hubHome,) = coinage.made(channel, name, symbol, decimals, supply, tokenSalt);
    }

    /**
     * @notice Create a hub token, a Manifold clone for it, and a
     *         NeutrinoSource clone that bundles them together. Idempotent.
     * @dev    Hub-side setup (channel, hub token, Manifold) is performed on
     *         the prototype before invoking inherited {Prototype.make} so the
     *         hub channel is keyed by {proto} — one channel per tick range,
     *         shared across all NeutrinoSource clones. Spoke channels (made
     *         inside {launch}) are keyed by the calling clone instead.
     * @param  name      Hub token name.
     * @param  symbol    Hub token symbol.
     * @param  decimals  Hub token decimals.
     * @param  supply    Hub token supply (entire supply funds the ETH/hub pool).
     * @param  tickLower Lower tick for the hub's ETH pool.
     * @param  tickUpper Upper tick for the hub's ETH pool.
     * @param  tokenSalt Salt for the Coinage hub token.
     * @param  variant   Salt variant (free for vanity grinding).
     * @return clone The deployed (or existing) NeutrinoSource clone.
     */
    function make(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenSalt,
        uint256 variant
    ) external returns (NeutrinoSource clone) {
        if (address(this) != proto) {
            return NeutrinoSource(proto).make(name, symbol, decimals, supply, tickLower, tickUpper, tokenSalt, variant);
        }

        bytes memory args = encode(name, symbol, decimals, supply, tickLower, tickUpper, tokenSalt);
        (bool exists, address home,) = this.made(args, variant);
        clone = NeutrinoSource(home);

        if (!exists) {
            NeutrinoChannel hubChannel = channelProto.make(tickLower, tickUpper, 0);
            IERC20Metadata hubToken = hubChannel.mint(coinage, name, symbol, decimals, supply, tokenSalt);

            (, address springHome,) = springProto.made(hubToken, tickLower, tickUpper);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            hubToken.transfer(springHome, supply);
            Manifold manifold = springProto.make(hubToken, tickLower, tickUpper);

            this.make(args, variant);
            emit Make(clone, hubToken, manifold);
        }
    }

    /**
     * @inheritdoc IPrototype
     * @dev Decodes the hub-token args, predicts the Manifold address for this
     *      clone's hub, and stores it as {spring}. {make} pre-deploys the
     *      underlying hub channel, hub token, and Manifold before invoking
     *      inherited {Prototype.make}, so all predicted addresses already
     *      exist by the time this runs.
     */
    function zzInit(bytes calldata args, uint256 variant) public override {
        super.zzInit(args, variant);
        (
            string memory name,
            string memory symbol,
            uint8 decimals,
            uint256 supply,
            int24 tickLower,
            int24 tickUpper,
            uint256 tokenSalt
        ) = abi.decode(args, (string, string, uint8, uint256, int24, int24, uint256));
        (, address channel,) = channelProto.made(proto, tickLower, tickUpper, 0);
        (, address hubHome,) = coinage.made(channel, name, symbol, decimals, supply, tokenSalt);
        (, address springHome,) = springProto.made(IERC20Metadata(hubHome), tickLower, tickUpper);
        spring = Manifold(springHome);
    }
}
