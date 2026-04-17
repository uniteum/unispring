// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";

import {NeutrinoMaker} from "./NeutrinoMaker.sol";
import {Unispring} from "./Unispring.sol";

/**
 * @title Neutrino
 * @notice One-click fair-launch factory. A Neutrino clone bundles a Lepton hub
 *         token with a Unispring clone. Call {launch} on a clone to create a
 *         spoke token whose entire supply is deposited as permanent liquidity,
 *         paired against the hub.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Neutrino {
    /**
     * @notice The prototype instance that acts as the Bitsy factory.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Neutrino public immutable PROTO;

    /**
     * @notice The Lepton prototype used to create hub and spoke tokens.
     */
    ICoinage public immutable LEPTON;

    /**
     * @notice The NeutrinoMaker prototype cloned per tick range so each range
     *         produces a distinct Lepton deployer (and therefore hub) address.
     */
    NeutrinoMaker public immutable MAKER;

    /**
     * @notice The Unispring prototype used to create fair-launch pools.
     */
    // forge-lint: disable-next-line(screaming-snake-case-immutable)
    Unispring public immutable UNISPRING;

    /**
     * @notice The hub token for this clone, set by {zzInit}.
     */
    ICoinage public hub;

    /**
     * @notice The Unispring clone for this clone's hub token, set by {zzInit}.
     */
    Unispring public spring;

    /**
     * @notice Emitted when a new clone is created via {make}.
     */
    event Make(Neutrino indexed clone, ICoinage indexed hub, Unispring indexed spring);

    /**
     * @notice Emitted when a spoke token is launched via {launch}.
     */
    event Launch(ICoinage indexed token, uint256 supply, int24 tickLower, int24 tickUpper);

    /**
     * @notice Thrown when {zzInit} is called by anyone other than {PROTO}.
     */
    error Unauthorized();

    /**
     * @notice Construct the prototype.
     * @param lepton    The Lepton prototype (ICoinage).
     * @param maker     The NeutrinoMaker prototype.
     * @param unispring The Unispring prototype.
     */
    constructor(ICoinage lepton, NeutrinoMaker maker, Unispring unispring) {
        PROTO = this;
        LEPTON = lepton;
        MAKER = maker;
        UNISPRING = unispring;
    }

    // ---- Bitsy factory ----

    /**
     * @notice Predict the deterministic address of a clone.
     * @param name       Hub token name (passed to Lepton).
     * @param symbol     Hub token symbol (passed to Lepton).
     * @param supply     Hub token supply (passed to Lepton).
     * @param leptonSalt Salt for the Lepton hub token.
     * @return exists  True if the clone is already deployed.
     * @return home    The deterministic clone address.
     * @return salt    The CREATE2 salt (derived from the hub token address).
     * @return hubHome The deterministic hub token address.
     */
    function made(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        bytes32 leptonSalt
    ) public view returns (bool exists, address home, bytes32 salt, address hubHome) {
        (,address maker,) = MAKER.made(tickLower, tickUpper);
        (, hubHome,) = LEPTON.made(maker, name, symbol, supply, leptonSalt);
        salt = bytes32(uint256(uint160(hubHome)));
        home = Clones.predictDeterministicAddress(address(PROTO), salt, address(PROTO));
        exists = home.code.length > 0;
    }

    /**
     * @notice Create a hub token, a Unispring clone for it, and a Neutrino
     *         clone that bundles them together. Idempotent.
     * @param name       Hub token name.
     * @param symbol     Hub token symbol.
     * @param supply     Hub token supply (entire supply funds the ETH/hub pool).
     * @param tickLower  Lower tick for the hub's ETH pool.
     * @param tickUpper  Upper tick for the hub's ETH pool.
     * @param leptonSalt Salt for the Lepton hub token.
     * @return clone The deployed (or existing) Neutrino clone.
     */
    function make(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        bytes32 leptonSalt
    ) external returns (Neutrino clone) {
        if (this != PROTO) {
            clone = PROTO.make(name, symbol, supply, tickLower, tickUpper, leptonSalt);
        } else {
            NeutrinoMaker maker = MAKER.make(tickLower, tickUpper);
            ICoinage hubToken = maker.mint(LEPTON, name, symbol, supply, leptonSalt);

            (bool exists, address home, bytes32 salt,) = made(name, symbol, supply, tickLower, tickUpper, leptonSalt);
            clone = Neutrino(home);
            if (!exists) {
                (, address springHome,) = UNISPRING.made(IERC20(address(hubToken)), tickLower, tickUpper);
                // forge-lint: disable-next-line(erc20-unchecked-transfer)
                IERC20(address(hubToken)).transfer(springHome, supply);

                Unispring springClone = UNISPRING.make(IERC20(address(hubToken)), tickLower, tickUpper);

                Clones.cloneDeterministic(address(PROTO), salt);
                Neutrino(home).zzInit(name, symbol, supply, tickLower, tickUpper, leptonSalt);
                emit Make(clone, hubToken, springClone);
            }
        }
    }

    /**
     * @notice Initializer called by PROTO on a freshly deployed clone. Derives
     *         the hub and spring addresses from the same parameters as {make}.
     * @param name       Hub token name.
     * @param symbol     Hub token symbol.
     * @param supply     Hub token supply.
     * @param tickLower  Lower tick for the hub's ETH pool.
     * @param tickUpper  Upper tick for the hub's ETH pool.
     * @param leptonSalt Salt for the Lepton hub token.
     */
    function zzInit(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper,
        bytes32 leptonSalt
    ) external {
        if (msg.sender != address(PROTO)) revert Unauthorized();
        (,address maker,) = MAKER.made(tickLower, tickUpper);
        (, address hubHome,) = LEPTON.made(maker, name, symbol, supply, leptonSalt);
        hub = ICoinage(hubHome);
        (, address springHome,) = UNISPRING.made(IERC20(hubHome), tickLower, tickUpper);
        spring = Unispring(payable(springHome));
    }

    // ---- Fair launch ----

    /**
     * @notice Create a spoke token via Lepton and deposit its entire supply as
     *         permanent liquidity on this clone's Unispring, paired against the
     *         hub. Permissionless — anyone can launch a spoke.
     * @param name      Spoke token name.
     * @param symbol    Spoke token symbol.
     * @param supply    Spoke token supply (entire supply is funded).
     * @param salt      Salt for the Lepton spoke token.
     * @param tickLower Lower tick (price floor in spoke-in-hub terms).
     * @param tickUpper Upper tick of the position.
     * @return token The newly created spoke token.
     */
    function launch(
        string calldata name,
        string calldata symbol,
        uint256 supply,
        bytes32 salt,
        int24 tickLower,
        int24 tickUpper
    ) external returns (ICoinage token) {
        token = LEPTON.make(name, symbol, supply, salt);
        IERC20(address(token)).approve(address(spring), supply);
        spring.fund(IERC20(address(token)), supply, tickLower, tickUpper);
        emit Launch(token, supply, tickLower, tickUpper);
    }
}
