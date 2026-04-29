// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IPlacer} from "./IPlacer.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title Mimicoinage
 * @notice Bitsy factory: each clone mints a fresh ERC-20 pegged 1:1 against
 *         a given original currency (ERC-20 or native ETH) and seats its
 *         entire supply as a single-tick segment in {placer}. The clone
 *         carries the per-instance (original, mimic) state; the prototype
 *         is just code.
 * @dev    The mimic token carries the original's decimals (18 for native
 *         ETH) so the raw price of 1 at tick 0 corresponds to a 1:1
 *         human-unit peg. Each position uses {Fountain.fee} (0.01%),
 *         {tickSpacing} = 1, and no hook. The user-semantic range is
 *         `[0, 1)`; Fountain flips and negates into V4-native ticks
 *         internally when the mimic sorts above the original, so both
 *         orderings seat only the mimic at genesis with tick 0 at the
 *         edge of the V4 range.
 * @dev    Each clone's deterministic address derives from `(original,
 *         symbol)`, so `(USDC, "USDCx1")` and `(DAI, "USDCx1")` are
 *         distinct clones and mint distinct mimic tokens. All fee
 *         machinery — {Fountain.take}, {Fountain.untaken},
 *         {Fountain.owner} — lives on Fountain.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Mimicoinage {
    string public constant version = "0.7.0";

    /**
     * @notice Cap on the raw supply minted for any mimic. Sized to stay
     *         well below the `maxLiquidityPerTick` cap at `tickSpacing = 1`
     *         for any reasonable decimals, so a single-tick position
     *         seating the full mimic supply cannot overflow V4's per-tick
     *         liquidity limit. ERC-20 mimics use the lesser of this cap
     *         and the original's total supply; native ETH mimics (no
     *         on-chain `totalSupply` to mirror) always use this value.
     */
    uint128 public constant maxSupply = 10 ** 27;

    /**
     * @notice The prototype instance that acts as the Bitsy factory.
     */
    Mimicoinage public immutable proto;

    /**
     * @notice The Fountain that holds each mimic's single-tick position
     *         and routes its swap fees to {Fountain.owner}.
     */
    IPlacer public immutable placer;

    /**
     * @notice The Coinage factory used to mint each clone's mimic ERC-20.
     */
    ICoinage public immutable coinage;

    /**
     * @notice The original currency this clone's mimic is pegged against
     *         (`Currency.wrap(address(0))` for native ETH). Set once by
     *         {zzInit}.
     */
    Currency public original;

    /**
     * @notice The mimic ERC-20 minted by this clone. Set once by {zzInit}.
     */
    IERC20Metadata public mimic;

    /**
     * @notice Emitted when a new clone is created via {make}.
     * @param  clone     The newly deployed Mimicoinage clone.
     * @param  original  The original currency the clone's mimic is pegged
     *                   against (`Currency.wrap(address(0))` for native ETH).
     * @param  mimic     The mimic ERC-20 minted by the clone.
     */
    event Make(Mimicoinage indexed clone, Currency indexed original, IERC20Metadata indexed mimic);

    /**
     * @notice Thrown when {zzInit} is called by anyone other than {proto}.
     */
    error Unauthorized();

    /**
     * @notice Construct the prototype. Clones are created via {make}.
     * @param  fountain The Fountain that will seat every mimic position
     *                  funded through this Mimicoinage.
     * @param  minter   The Coinage prototype used to mint mimics.
     */
    constructor(IPlacer fountain, ICoinage minter) {
        proto = this;
        placer = fountain;
        coinage = minter;
    }

    // ---- Bitsy factory ----

    /**
     * @notice Predict the deterministic address of a clone for `(original_,
     *         symbol)`, and the address of the mimic it would mint.
     * @param  original_ The reference currency that would be pegged against
     *                   (`Currency.wrap(address(0))` for native ETH).
     * @param  symbol    Symbol that would be used for the mimic ERC-20.
     * @return exists    True if the clone is already deployed.
     * @return home      The deterministic clone address.
     * @return salt      The CREATE2 salt (derived from the input parameters).
     * @return mimicHome The deterministic mimic-token address.
     */
    function made(Currency original_, string calldata symbol)
        public
        view
        returns (bool exists, address home, bytes32 salt, address mimicHome)
    {
        salt = keccak256(abi.encode(original_, symbol));
        home = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        exists = home.code.length > 0;
        (uint8 decimals, uint256 supply) = _mimicMetadata(original_);
        (, mimicHome,) = coinage.made(home, symbol, symbol, decimals, supply, bytes32(0));
    }

    /**
     * @notice Deploy a deterministic Mimicoinage clone for `(original_,
     *         symbol)`. The clone mints its mimic and seats the entire
     *         supply at the 1:1 edge in {placer}. Idempotent — returns the
     *         existing clone if already deployed.
     * @param  original_ The reference currency to peg against
     *                   (`Currency.wrap(address(0))` for native ETH; the
     *                   mimic is minted with 18 decimals in that case).
     * @param  symbol    Symbol for the newly minted mimic. Used as both
     *                   name and symbol on the underlying ERC-20.
     * @return clone     The deployed (or existing) clone.
     */
    function make(Currency original_, string calldata symbol) external returns (Mimicoinage clone) {
        if (address(this) != address(proto)) {
            clone = proto.make(original_, symbol);
        } else {
            (bool exists, address home, bytes32 salt,) = made(original_, symbol);
            clone = Mimicoinage(home);
            if (!exists) {
                Clones.cloneDeterministic(address(proto), salt, 0);
                Mimicoinage(home).zzInit(original_, symbol);
                emit Make(clone, original_, clone.mimic());
            }
        }
    }

    /**
     * @notice Initializer for a freshly deployed clone. Mints the mimic via
     *         {coinage}, seats its entire supply as a single-tick segment
     *         in {placer}, and records the (original, mimic) pair on this
     *         clone. Callable only by {proto}.
     * @dev    The clone is the Coinage maker, so the per-clone deployer
     *         address gives every `(original, symbol)` pair a distinct
     *         mimic address even when decimals and supply collide.
     */
    function zzInit(Currency original_, string calldata symbol) external {
        if (msg.sender != address(proto)) revert Unauthorized();
        original = original_;
        (uint8 decimals, uint256 supply) = _mimicMetadata(original_);
        IERC20Metadata token = coinage.make(symbol, symbol, decimals, supply, bytes32(0));
        mimic = token;

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.approve(address(placer), supply);

        int24[] memory ticks = new int24[](2);
        ticks[0] = 0;
        ticks[1] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = supply;

        placer.offer(Currency.wrap(address(token)), original_, ticks, amounts);
    }

    /**
     * @dev Resolve the decimals and supply used to mint a mimic of
     *      `original_`. ERC-20 originals contribute their decimals 1:1
     *      and the lesser of `original_.totalSupply()` and {maxSupply} —
     *      capping at {maxSupply} so an oversized original cannot overflow
     *      `maxLiquidityPerTick` when its mimic is seated single-sided
     *      in a one-tick range. Native ETH (`address(0)`) has no on-chain
     *      metadata, so the mimic uses 18 decimals (the conventional
     *      human-unit semantics) and {maxSupply}.
     */
    function _mimicMetadata(Currency original_) private view returns (uint8 decimals, uint256 supply) {
        if (original_.isAddressZero()) return (18, maxSupply);
        IERC20Metadata erc = IERC20Metadata(Currency.unwrap(original_));
        uint256 originalSupply = erc.totalSupply();
        return (erc.decimals(), originalSupply < maxSupply ? originalSupply : maxSupply);
    }
}
