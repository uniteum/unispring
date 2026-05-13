// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {IStringLookup} from "ilookup/IStringLookup.sol";
import {ICoinage} from "icoinage/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IReflector} from "iunispring/IReflector.sol";
import {IReflectorMaker} from "iunispring/IReflectorMaker.sol";
import {IPlacer} from "iunispring/IPlacer.sol";
import {IPrototype} from "iproto/IPrototype.sol";
import {Prototype} from "proto/Prototype.sol";

/**
 * @title Reflector
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
contract Reflector is Prototype, IReflectorMaker, IReflector {
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
     * @notice The Fountain that holds each issue's single-tick position
     *         and routes its swap fees to {Fountain.owner}.
     */
    IPlacer public immutable placer;

    /**
     * @notice The Coinage factory used to mint each clone's issue ERC-20s.
     */
    ICoinage public immutable coinage;

    /**
     * @inheritdoc IReflector
     * @dev Set on clones by {zzInit}; the prototype's value is the
     *      storage default `address(0)` (native ETH).
     */
    address public original;

    /**
     * @inheritdoc IReflector
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
     *                            position funded through this Reflector.
     * @param  minter             The Coinage prototype used to mint issues.
     * @param  gasSymbolLookup Chain-local {IStringLookup} whose `value()`
     *                            returns the native currency symbol (e.g.
     *                            "ETH" on mainnet, "MATIC" on Polygon); used
     *                            as the suffix for the prototype's issue
     *                            symbol `"1x<native>"`.
     */
    constructor(IPlacer fountain, ICoinage minter, IStringLookup gasSymbolLookup) {
        placer = fountain;
        coinage = minter;
        symbol = string.concat("1x", gasSymbolLookup.value());
        emit Make(address(this), address(0), symbol);
    }

    // ---- Bitsy factory: issues ----

    /**
     * @inheritdoc IReflector
     */
    function issued(address original_, string calldata symbol_, string calldata name_)
        public
        view
        override
        returns (bool exists, address home)
    {
        (, address maker,) = made(original_, symbol_);
        return _issued(maker, _resolve(original_), symbol_, name_);
    }

    /**
     * @inheritdoc IReflector
     */
    function issued(string calldata name_) external view override returns (bool exists, address home) {
        return _issued(address(this), original, symbol, name_);
    }

    /**
     * @inheritdoc IReflector
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

    // ---- Bitsy factory: clones ----

    /**
     * @notice ABI-encode the per-clone init args.
     * @dev    The returned bytes are the canonical args passed to
     *         {Prototype.make} and {zzInit}. The clone's address is keyed
     *         by `(original, symbol)` so the typed wrappers always use the
     *         default variant `0`; bytes-form callers passing a non-zero
     *         variant would land on a separate clone whose {zzInit} reverts
     *         on the proto-pair check, but is otherwise valid.
     */
    function encode(address original_, string memory symbol_) public pure returns (bytes memory args) {
        args = abi.encode(original_, symbol_);
    }

    /**
     * @inheritdoc IReflectorMaker
     */
    function made(address original_, string calldata symbol_)
        public
        view
        override
        returns (bool exists, address home, bytes32 salt)
    {
        if (_isProtoPair(_resolve(original_), symbol_)) {
            return (true, proto, bytes32(0));
        }
        (exists, home, salt) = this.made(encode(original_, symbol_), 0);
    }

    /**
     * @inheritdoc IReflectorMaker
     */
    function make(address original_, string calldata symbol_) external override returns (address clone) {
        address resolved = _resolve(original_);
        if (_isProtoPair(resolved, symbol_)) {
            clone = proto;
        } else {
            (bool exists, address home,) = this.make(encode(original_, symbol_), 0);
            clone = home;
            if (!exists) emit Make(home, resolved, symbol_);
        }
    }

    /**
     * @inheritdoc IPrototype
     * @dev Decodes `(original_, symbol_)`, resolves any {IAddressLookup} to
     *      its underlying address, and records the pair on the clone.
     *      Reverts if the args encode the proto pair so the prototype
     *      remains the sole canonical factory for `(native ETH, proto.symbol())`
     *      even when callers bypass the typed wrappers.
     */
    function zzInit(bytes calldata args, uint256 variant) public override {
        super.zzInit(args, variant);
        (address original_, string memory symbol_) = abi.decode(args, (address, string));
        address resolved = _resolve(original_);
        if (_isProtoPair(resolved, symbol_)) revert ProtoPairReserved();
        original = resolved;
        symbol = symbol_;
    }

    /**
     * @dev True when `(original_, symbol_)` is the prototype's own pair
     *      `(native ETH, proto.symbol())`, i.e. the pair for which the
     *      prototype itself is the factory.
     */
    function _isProtoPair(address original_, string memory symbol_) private view returns (bool) {
        return original_ == address(0) && keccak256(bytes(symbol_)) == keccak256(bytes(Reflector(proto).symbol()));
    }
}
