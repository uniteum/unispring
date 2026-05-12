// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {Clones} from "clones/Clones.sol";
import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IStringLookup} from "ilookup/IStringLookup.sol";
import {ICoinage} from "icoinage/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {INotable} from "iunispring/INotable.sol";
import {INotableMaker} from "iunispring/INotableMaker.sol";
import {IPlacer} from "iunispring/IPlacer.sol";

/**
 * @title Notable
 * @notice Two-level Bitsy factory. The prototype mints clones keyed by
 *         `(original, symbol)`; each clone is itself a token factory
 *         that issues ERC-20s — one per `name`, all sharing the
 *         clone's `(original, symbol)`. Each issued token is pegged 1:1
 *         against the clone's original (ERC-20 or native ETH) and has
 *         its entire supply seated as a single-tick segment in {placer}.
 * @notice The prototype is itself the canonical factory for the
 *         pair `(native ETH, "1x<native>")`, where `<native>` is the
 *         native currency symbol resolved from a chain-local
 *         {IStringLookup} at construction (e.g. "1xETH" on mainnet,
 *         "1xMATIC" on Polygon). `proto.issue(name)` mints the pegged
 *         ERC-20 directly from the prototype, and
 *         `make(address(0), proto.symbol())` returns `proto` (no
 *         separate clone is deployed for that pair).
 * @dev    The issued token carries the original's decimals (18 for native
 *         ETH) so the raw price of 1 at tick 0 corresponds to a 1:1
 *         human-unit peg. Each position uses {Fountain.fee} (0.01%),
 *         {tickSpacing} = 1, and no hook. The user-semantic range is
 *         `[0, 1)`; Fountain flips and negates into V4-native ticks
 *         internally when the issue sorts above the original, so both
 *         orderings seat only the issue at genesis with tick 0 at the
 *         edge of the V4 range.
 * @dev    A clone's deterministic address derives from `(original,
 *         symbol)`, so `(USDC, "USDCx1")` and `(DAI, "USDCx1")` are
 *         distinct clones. Within a clone, each issue's deterministic
 *         address derives from `(clone, name, symbol, decimals, supply)`,
 *         so `clone.issue("alpha")` and `clone.issue("beta")` are
 *         distinct tokens. All fee machinery — {Fountain.take},
 *         {Fountain.untaken}, {Fountain.owner} — lives on Fountain.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Notable is INotableMaker, INotable {
    string public constant version = "0.8.0";

    /**
     * @notice Raw supply minted for an issue with 18 or more decimals.
     *         Issues with fewer decimals reduce this by a factor of 10
     *         per decimal below 18, keeping the human-unit supply
     *         roughly constant across originals. Sized to stay well
     *         below the `maxLiquidityPerTick` cap at `tickSpacing = 1`
     *         for any reasonable decimals, so a single-tick position
     *         seating the full issue supply cannot overflow V4's
     *         per-tick liquidity limit. Native ETH issues use 18
     *         decimals and this value directly.
     */
    uint128 public constant maxSupply = 10 ** 27;

    /**
     * @notice The prototype instance that acts as the clone factory.
     */
    Notable public immutable proto;

    /**
     * @notice The Fountain that holds each issue's single-tick position
     *         and routes its swap fees to {Fountain.owner}.
     */
    IPlacer public immutable placer;

    /**
     * @notice The Coinage factory used to mint each clone's issue ERC-20s.
     */
    ICoinage public immutable coinage;

    /**
     * @inheritdoc INotable
     * @dev Set on clones by {zzInit}; the prototype's value is the
     *      storage default `address(0)` (native ETH).
     */
    address public original;

    /**
     * @inheritdoc INotable
     * @dev Set on clones by {zzInit}; the prototype's value is
     *      `"1x<native>"`, derived from the chain-local {IStringLookup}
     *      passed at construction.
     */
    string public symbol;

    /**
     * @notice Construct the prototype. Clones are created via {make}.
     *         The prototype itself acts as the
     *         `(native ETH, "1x<native>")` factory: its `original` is
     *         the storage-default native ETH and its `symbol` is
     *         `string.concat("1x", gasSymbolLookup.value())`
     *         resolved from the chain-local lookup at construction.
     * @param  fountain           The Fountain that will seat every issue
     *                            position funded through this Notable.
     * @param  minter             The Coinage prototype used to mint issues.
     * @param  gasSymbolLookup Chain-local {IStringLookup} whose `value()`
     *                            returns the native currency symbol (e.g.
     *                            "ETH" on mainnet, "MATIC" on Polygon); used
     *                            as the suffix for the prototype's issue
     *                            symbol `"1x<native>"`.
     */
    constructor(IPlacer fountain, ICoinage minter, IStringLookup gasSymbolLookup) {
        proto = this;
        placer = fountain;
        coinage = minter;
        symbol = string.concat("1x", gasSymbolLookup.value());
        emit Make(address(this), address(0), symbol);
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
     * @param  symbol_   The shared symbol every issue minted by the clone
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
        override
        returns (bool exists, address home, bytes32 salt)
    {
        if (_isProtoPair(_resolve(original_), symbol_)) {
            return (true, address(proto), bytes32(0));
        }
        salt = keccak256(abi.encode(original_, symbol_));
        home = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy a deterministic Notable clone for `(original_,
     *         symbol_)`. Idempotent — returns the existing clone if
     *         already deployed. For the proto pair
     *         `(native ETH, "1xETH")` this returns `proto` directly
     *         (no clone is deployed; the proto IS the factory for that
     *         pair). The clone issues tokens via {issue}.
     * @param  original_ The reference token to peg against. `address(0)`
     *                   selects native ETH (issues minted with 18 decimals);
     *                   an {IAddressLookup} resolves to its `value()` address
     *                   (the chain-local token); any other address is treated
     *                   as the token directly. The salt is computed from
     *                   this raw input, so the same {IAddressLookup} yields
     *                   the same clone address across chains.
     * @param  symbol_   Shared symbol every issue minted by this clone
     *                   will carry.
     * @return clone     The deployed (or existing) clone, or `proto`
     *                   itself for the proto pair.
     */
    function make(address original_, string calldata symbol_) external override returns (address clone) {
        if (address(this) != address(proto)) {
            clone = proto.make(original_, symbol_);
        } else {
            address resolved = _resolve(original_);
            if (_isProtoPair(resolved, symbol_)) {
                clone = address(this);
            } else {
                (bool exists, address home, bytes32 salt) = made(original_, symbol_);
                clone = home;
                if (!exists) {
                    Clones.cloneDeterministic(address(proto), salt, 0);
                    Notable(home).zzInit(resolved, symbol_);
                    emit Make(home, resolved, symbol_);
                }
            }
        }
    }

    /**
     * @notice Initializer for a freshly deployed clone. Records the
     *         shared `(original, symbol)` on this clone. Callable only
     *         by {proto}.
     */
    function zzInit(address original_, string calldata symbol_) external {
        if (msg.sender != address(proto)) revert Unauthorized();
        original = original_;
        symbol = symbol_;
    }

    // ---- Bitsy factory: issues ----

    /**
     * @notice Predict the deterministic address of an issue minted by the
     *         clone for `(original_, symbol_)` with `name_`. Works whether
     *         or not the clone is already deployed.
     * @param  original_ The reference token, accepted under the same rules
     *                   as {make} / {made}: `address(0)` is native ETH;
     *                   an {IAddressLookup} resolves through `value()`;
     *                   any other address is the token itself.
     * @param  symbol_   Shared symbol every issue of the clone carries.
     * @param  name_     Per-issue name.
     * @return exists    True if the issue token is already deployed.
     * @return home      The deterministic issue address.
     */
    function issued(address original_, string calldata symbol_, string calldata name_)
        public
        view
        override
        returns (bool exists, address home)
    {
        address resolved = _resolve(original_);
        address maker;
        if (_isProtoPair(resolved, symbol_)) {
            maker = address(proto);
        } else {
            // forge-lint: disable-next-line(asm-keccak256)
            bytes32 salt = keccak256(abi.encode(original_, symbol_));
            maker = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        }
        return _issued(maker, resolved, symbol_, name_);
    }

    /**
     * @notice Predict the deterministic issue address for `name_` under
     *         this instance's stored `(original, symbol)`. Convenience
     *         wrapper for callers that already hold the clone (or proto):
     *         the maker for {coinage}'s CREATE2 is `address(this)`, so no
     *         salt rederivation is needed.
     */
    function issued(string calldata name_) external view override returns (bool exists, address home) {
        return _issued(address(this), original, symbol, name_);
    }

    /**
     * @notice Mint a fresh issue ERC-20 with `name_`, this instance's
     *         stored `symbol`, and decimals + supply derived from
     *         `original`, and seat its entire supply as a single-tick
     *         segment in {placer}. Idempotent — returns the existing
     *         token if an issue with `name_` was already minted by this
     *         instance. Callable on the prototype (mints under the
     *         proto pair `(native ETH, "1xETH")`) or on any clone
     *         (mints under that clone's pair).
     * @param  name_  Per-issue name. Must vary across calls to mint
     *                distinct issues under this instance's `(original,
     *                symbol)`.
     * @return token  The minted (or existing) issue ERC-20.
     */
    function issue(string calldata name_) external override returns (IERC20Metadata token) {
        (bool exists, address home) = _issued(address(this), original, symbol, name_);
        if (exists) return IERC20Metadata(home);

        (uint8 decimals, uint256 supply) = _issueMetadata(original);
        token = coinage.make(name_, symbol, decimals, supply, 0);

        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        token.approve(address(placer), supply);

        int24[] memory ticks = new int24[](2);
        ticks[0] = 0;
        ticks[1] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = supply;

        placer.offer(address(token), original, ticks, amounts);

        emit Issue(address(this), token, name_);
    }

    /**
     * @dev Ask {coinage} for the deterministic issue address `maker` would
     *      produce for `(name_, symbol_)` with metadata derived from
     *      `original_`. Callers from this instance (action {issue} and
     *      convenience {issued}) pass `address(this)`; the public
     *      {issued} overload computes `maker` from the salted clone
     *      prediction since no clone instance is in scope yet.
     */
    function _issued(address maker, address original_, string memory symbol_, string memory name_)
        private
        view
        returns (bool exists, address home)
    {
        (uint8 decimals, uint256 supply) = _issueMetadata(original_);
        (exists, home,) = coinage.made(maker, name_, symbol_, decimals, supply, 0);
    }

    /**
     * @dev True when `(original_, symbol_)` is the prototype's own pair
     *      `(native ETH, proto.symbol())`, i.e. the pair for which the
     *      prototype itself is the factory.
     */
    function _isProtoPair(address original_, string memory symbol_) private view returns (bool) {
        return original_ == address(0) && keccak256(bytes(symbol_)) == keccak256(bytes(proto.symbol()));
    }

    /**
     * @dev Resolve `original_` into the underlying token address.
     *      `address(0)` is native ETH; an {IAddressLookup} resolves to
     *      its `value()`; any other address is treated as the token
     *      itself. A `value()` that returns `address(0)` resolves to
     *      native ETH.
     */
    function _resolve(address original_) private view returns (address) {
        if (original_ == address(0)) return address(0);
        if (original_.code.length == 0) return original_;
        try IAddressLookup(original_).value() returns (address resolved) {
            return resolved;
        } catch {
            return original_;
        }
    }

    /**
     * @dev Resolve the decimals and supply used to mint an issue of
     *      `original_`. ERC-20 originals contribute their decimals 1:1
     *      and a decimals-adjusted supply: {maxSupply} when decimals are
     *      18 or more, reduced by a factor of 10 per decimal below 18 —
     *      sized to stay below `maxLiquidityPerTick` when the issue is
     *      seated single-sided in a one-tick range. Native ETH
     *      (`address(0)`) has no on-chain metadata, so the issue uses 18
     *      decimals (the conventional human-unit semantics) and
     *      {maxSupply}.
     */
    function _issueMetadata(address original_) private view returns (uint8 decimals, uint256 supply) {
        if (original_ == address(0)) return (18, maxSupply);
        decimals = IERC20Metadata(original_).decimals();
        supply = uint256(maxSupply);
        if (decimals < 18) supply /= 10 ** uint256(18 - decimals);
    }
}
