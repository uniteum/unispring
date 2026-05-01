// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IPlacer} from "./IPlacer.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title Mimicry
 * @notice Two-level Bitsy factory. The prototype mints clones keyed by
 *         `(original, symbol)`; each clone is itself a token factory
 *         that mints mimic ERC-20s — one per `name`, all sharing the
 *         clone's `(original, symbol)`. Each minted mimic is pegged 1:1
 *         against the clone's original (ERC-20 or native ETH) and has
 *         its entire supply seated as a single-tick segment in {placer}.
 * @notice The prototype is itself the canonical factory for the
 *         `(native ETH, "1xETH")` pair: `proto.mimic(name)` mints a
 *         1xETH ERC-20 directly from the prototype, and
 *         `make(address(0), "1xETH")` returns `proto` (no separate
 *         clone is deployed for that pair).
 * @dev    The mimic token carries the original's decimals (18 for native
 *         ETH) so the raw price of 1 at tick 0 corresponds to a 1:1
 *         human-unit peg. Each position uses {Fountain.fee} (0.01%),
 *         {tickSpacing} = 1, and no hook. The user-semantic range is
 *         `[0, 1)`; Fountain flips and negates into V4-native ticks
 *         internally when the mimic sorts above the original, so both
 *         orderings seat only the mimic at genesis with tick 0 at the
 *         edge of the V4 range.
 * @dev    A clone's deterministic address derives from `(original,
 *         symbol)`, so `(USDC, "USDCx1")` and `(DAI, "USDCx1")` are
 *         distinct clones. Within a clone, each mimic's deterministic
 *         address derives from `(clone, name, symbol, decimals, supply)`,
 *         so `clone.mimic("alpha")` and `clone.mimic("beta")` are
 *         distinct tokens. All fee machinery — {Fountain.take},
 *         {Fountain.untaken}, {Fountain.owner} — lives on Fountain.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Mimicry {
    string public constant version = "0.7.0";

    /**
     * @notice Raw supply minted for a mimic with 18 or more decimals.
     *         Mimics with fewer decimals reduce this by a factor of 10
     *         per decimal below 18, keeping the human-unit supply
     *         roughly constant across originals. Sized to stay well
     *         below the `maxLiquidityPerTick` cap at `tickSpacing = 1`
     *         for any reasonable decimals, so a single-tick position
     *         seating the full mimic supply cannot overflow V4's
     *         per-tick liquidity limit. Native ETH mimics use 18
     *         decimals and this value directly.
     */
    uint128 public constant maxSupply = 10 ** 27;

    /**
     * @notice The prototype instance that acts as the clone factory.
     */
    Mimicry public immutable proto;

    /**
     * @notice The Fountain that holds each mimic's single-tick position
     *         and routes its swap fees to {Fountain.owner}.
     */
    IPlacer public immutable placer;

    /**
     * @notice The Coinage factory used to mint each clone's mimic ERC-20s.
     */
    ICoinage public immutable coinage;

    /**
     * @notice The original currency every mimic minted by this clone is
     *         pegged against (`Currency.wrap(address(0))` for native ETH).
     *         Set on clones by {zzInit}; the prototype's value is the
     *         storage default `Currency.wrap(address(0))` (native ETH).
     */
    Currency public original;

    /**
     * @notice The symbol shared by every mimic minted by this clone
     *         (mimics vary only by `name`). Set on clones by {zzInit};
     *         the prototype's value is set to `"1xETH"` in the
     *         constructor.
     */
    string public symbol;

    /**
     * @notice Emitted when a new clone is created via {make}.
     * @param  clone     The newly deployed Mimicry clone.
     * @param  original  The original currency the clone's mimics are
     *                   pegged against (`Currency.wrap(address(0))` for
     *                   native ETH).
     * @param  symbol    The shared symbol every mimic minted by this
     *                   clone carries.
     */
    event Make(Mimicry indexed clone, Currency indexed original, string symbol);

    /**
     * @notice Emitted when a clone mints a new mimic via {mimic}.
     * @param  clone The clone that minted the token.
     * @param  token The newly minted mimic ERC-20.
     * @param  name  The name carried by the token.
     */
    event Mimic(Mimicry indexed clone, IERC20Metadata indexed token, string name);

    /**
     * @notice Thrown when {zzInit} is called by anyone other than {proto}.
     */
    error Unauthorized();

    /**
     * @notice Construct the prototype. Clones are created via {make}.
     *         The prototype itself acts as the `(native ETH, "1xETH")`
     *         factory: its `original` is the storage-default native ETH
     *         and its `symbol` is set to `"1xETH"` here.
     * @param  fountain The Fountain that will seat every mimic position
     *                  funded through this Mimicry.
     * @param  minter   The Coinage prototype used to mint mimics.
     */
    constructor(IPlacer fountain, ICoinage minter) {
        proto = this;
        placer = fountain;
        coinage = minter;
        symbol = "1xETH";
        emit Make(this, Currency.wrap(address(0)), symbol);
    }

    // ---- Bitsy factory: clones ----

    /**
     * @notice Predict the deterministic address of a clone for `(original_,
     *         symbol_)`. For the proto pair `(native ETH, "1xETH")` this
     *         returns `(true, address(proto), bytes32(0))` — the proto
     *         itself serves as the canonical factory and no separate
     *         clone exists.
     * @param  original_ The reference token. `address(0)` selects native
     *                   ETH; an {IAddressLookup} resolves to its `value()`
     *                   address (the chain-local token); any other address
     *                   is treated as the token directly. The salt is
     *                   computed from this raw input, so passing the same
     *                   {IAddressLookup} on different chains yields the
     *                   same deterministic clone address even when the
     *                   resolved token differs.
     * @param  symbol_   The shared symbol every mimic minted by the clone
     *                   would carry.
     * @return exists    True if the clone is already deployed (always true
     *                   for the proto pair).
     * @return home      The deterministic clone address (or `address(proto)`
     *                   for the proto pair).
     * @return salt      The CREATE2 salt (`bytes32(0)` for the proto pair,
     *                   which never uses CREATE2).
     */
    function made(address original_, string calldata symbol_)
        public
        view
        returns (bool exists, address home, bytes32 salt)
    {
        if (_isProtoPair(_resolve(original_), symbol_)) return (true, address(proto), bytes32(0));
        salt = keccak256(abi.encode(original_, symbol_));
        home = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy a deterministic Mimicry clone for `(original_,
     *         symbol_)`. Idempotent — returns the existing clone if
     *         already deployed. For the proto pair
     *         `(native ETH, "1xETH")` this returns `proto` directly
     *         (no clone is deployed; the proto IS the factory for that
     *         pair). The clone mints mimic tokens via {mimic}.
     * @param  original_ The reference token to peg against. `address(0)`
     *                   selects native ETH (mimics minted with 18 decimals);
     *                   an {IAddressLookup} resolves to its `value()` address
     *                   (the chain-local token); any other address is treated
     *                   as the token directly. The salt is computed from
     *                   this raw input, so the same {IAddressLookup} yields
     *                   the same clone address across chains.
     * @param  symbol_   Shared symbol every mimic minted by this clone
     *                   will carry.
     * @return clone     The deployed (or existing) clone, or `proto`
     *                   itself for the proto pair.
     */
    function make(address original_, string calldata symbol_) external returns (Mimicry clone) {
        if (address(this) != address(proto)) {
            clone = proto.make(original_, symbol_);
        } else {
            Currency resolved = _resolve(original_);
            if (_isProtoPair(resolved, symbol_)) {
                clone = this;
            } else {
                (bool exists, address home, bytes32 salt) = made(original_, symbol_);
                clone = Mimicry(home);
                if (!exists) {
                    Clones.cloneDeterministic(address(proto), salt, 0);
                    Mimicry(home).zzInit(resolved, symbol_);
                    emit Make(clone, resolved, symbol_);
                }
            }
        }
    }

    /**
     * @notice Initializer for a freshly deployed clone. Records the
     *         shared `(original, symbol)` on this clone. Callable only
     *         by {proto}.
     */
    function zzInit(Currency original_, string calldata symbol_) external {
        if (msg.sender != address(proto)) revert Unauthorized();
        original = original_;
        symbol = symbol_;
    }

    // ---- Bitsy factory: mimics ----

    /**
     * @notice Predict the deterministic address of a mimic minted by the
     *         clone for `(original_, symbol_)` with `name_`. Works whether
     *         or not the clone is already deployed.
     * @param  original_ The reference token, accepted under the same rules
     *                   as {make} / {made}: `address(0)` is native ETH;
     *                   an {IAddressLookup} resolves through `value()`;
     *                   any other address is the token itself.
     * @param  symbol_   Shared symbol every mimic of the clone carries.
     * @param  name_     Per-mimic name.
     * @return exists    True if the mimic token is already deployed.
     * @return home      The deterministic mimic address.
     */
    function mimicked(address original_, string calldata symbol_, string calldata name_)
        public
        view
        returns (bool exists, address home)
    {
        Currency resolved = _resolve(original_);
        address maker;
        if (_isProtoPair(resolved, symbol_)) {
            maker = address(proto);
        } else {
            bytes32 salt = keccak256(abi.encode(original_, symbol_));
            maker = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        }
        return _mimicked(maker, resolved, symbol_, name_);
    }

    /**
     * @notice Predict the deterministic mimic address for `name_` under
     *         this instance's stored `(original, symbol)`. Convenience
     *         wrapper for callers that already hold the clone (or proto):
     *         the maker for {coinage}'s CREATE2 is `address(this)`, so no
     *         salt rederivation is needed.
     */
    function mimicked(string calldata name_) external view returns (bool exists, address home) {
        return _mimicked(address(this), original, symbol, name_);
    }

    /**
     * @notice Mint a fresh mimic ERC-20 with `name_`, this instance's
     *         stored `symbol`, and decimals + supply derived from
     *         `original`, and seat its entire supply as a single-tick
     *         segment in {placer}. Idempotent — returns the existing
     *         token if a mimic with `name_` was already minted by this
     *         instance. Callable on the prototype (mints under the
     *         proto pair `(native ETH, "1xETH")`) or on any clone
     *         (mints under that clone's pair).
     * @param  name_  Per-mimic name. Must vary across calls to mint
     *                distinct mimics under this instance's `(original,
     *                symbol)`.
     * @return token  The minted (or existing) mimic ERC-20.
     */
    function mimic(string calldata name_) external returns (IERC20Metadata token) {
        (bool exists, address home) = _mimicked(address(this), original, symbol, name_);
        if (exists) return IERC20Metadata(home);

        (uint8 decimals, uint256 supply) = _mimicMetadata(original);
        token = coinage.make(name_, symbol, decimals, supply, bytes32(0));

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.approve(address(placer), supply);

        int24[] memory ticks = new int24[](2);
        ticks[0] = 0;
        ticks[1] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = supply;

        placer.offer(Currency.wrap(address(token)), original, ticks, amounts);

        emit Mimic(this, token, name_);
    }

    /**
     * @dev Ask {coinage} for the deterministic mimic address `maker` would
     *      produce for `(name_, symbol_)` with metadata derived from
     *      `original_`. Callers from this instance (action {mimic} and
     *      convenience {mimicked}) pass `address(this)`; the public
     *      {mimicked} overload computes `maker` from the salted clone
     *      prediction since no clone instance is in scope yet.
     */
    function _mimicked(address maker, Currency original_, string memory symbol_, string memory name_)
        private
        view
        returns (bool exists, address home)
    {
        (uint8 decimals, uint256 supply) = _mimicMetadata(original_);
        (exists, home,) = coinage.made(maker, name_, symbol_, decimals, supply, bytes32(0));
    }

    /**
     * @dev True when `(original_, symbol_)` is the prototype's own pair
     *      `(native ETH, proto.symbol())`, i.e. the pair for which the
     *      prototype itself is the factory.
     */
    function _isProtoPair(Currency original_, string memory symbol_) private view returns (bool) {
        return original_.isAddressZero() && keccak256(bytes(symbol_)) == keccak256(bytes(proto.symbol()));
    }

    /**
     * @dev Resolve `original_` into a {Currency}. `address(0)` is native
     *      ETH; an {IAddressLookup} resolves to its `value()`; any other
     *      address is treated as the token itself. A `value()` that
     *      returns `address(0)` resolves to native ETH.
     */
    function _resolve(address original_) private view returns (Currency) {
        if (original_ == address(0)) return Currency.wrap(address(0));
        if (original_.code.length == 0) return Currency.wrap(original_);
        try IAddressLookup(original_).value() returns (address resolved) {
            return Currency.wrap(resolved);
        } catch {
            return Currency.wrap(original_);
        }
    }

    /**
     * @dev Resolve the decimals and supply used to mint a mimic of
     *      `original_`. ERC-20 originals contribute their decimals 1:1
     *      and a decimals-adjusted supply: {maxSupply} when decimals are
     *      18 or more, reduced by a factor of 10 per decimal below 18 —
     *      sized to stay below `maxLiquidityPerTick` when the mimic is
     *      seated single-sided in a one-tick range. Native ETH
     *      (`address(0)`) has no on-chain metadata, so the mimic uses 18
     *      decimals (the conventional human-unit semantics) and
     *      {maxSupply}.
     */
    function _mimicMetadata(Currency original_) private view returns (uint8 decimals, uint256 supply) {
        if (original_.isAddressZero()) return (18, maxSupply);
        decimals = IERC20Metadata(Currency.unwrap(original_)).decimals();
        supply = uint256(maxSupply);
        if (decimals < 18) supply /= 10 ** uint256(18 - decimals);
    }
}
