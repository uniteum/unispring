// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
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
 *         `make(Currency.wrap(address(0)), "1xETH")` returns `proto`
 *         (no separate clone is deployed for that pair).
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
     * @param  original_ The reference currency that would be pegged against
     *                   (`Currency.wrap(address(0))` for native ETH).
     * @param  symbol_   The shared symbol every mimic minted by the clone
     *                   would carry.
     * @return exists    True if the clone is already deployed (always true
     *                   for the proto pair).
     * @return home      The deterministic clone address (or `address(proto)`
     *                   for the proto pair).
     * @return salt      The CREATE2 salt (`bytes32(0)` for the proto pair,
     *                   which never uses CREATE2).
     */
    function made(Currency original_, string calldata symbol_)
        public
        view
        returns (bool exists, address home, bytes32 salt)
    {
        if (_isProtoPair(original_, symbol_)) return (true, address(proto), bytes32(0));
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
     * @param  original_ The reference currency to peg against
     *                   (`Currency.wrap(address(0))` for native ETH;
     *                   mimics are minted with 18 decimals in that case).
     * @param  symbol_   Shared symbol every mimic minted by this clone
     *                   will carry.
     * @return clone     The deployed (or existing) clone, or `proto`
     *                   itself for the proto pair.
     */
    function make(Currency original_, string calldata symbol_) external returns (Mimicry clone) {
        if (address(this) != address(proto)) {
            clone = proto.make(original_, symbol_);
        } else if (_isProtoPair(original_, symbol_)) {
            clone = this;
        } else {
            (bool exists, address home, bytes32 salt) = made(original_, symbol_);
            clone = Mimicry(home);
            if (!exists) {
                Clones.cloneDeterministic(address(proto), salt, 0);
                Mimicry(home).zzInit(original_, symbol_);
                emit Make(clone, original_, symbol_);
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
     * @param  original_ The reference currency the clone would peg against.
     * @param  symbol_   Shared symbol every mimic of the clone carries.
     * @param  name_     Per-mimic name.
     * @return exists    True if the mimic token is already deployed.
     * @return home      The deterministic mimic address.
     */
    function mimicked(Currency original_, string calldata symbol_, string calldata name_)
        public
        view
        returns (bool exists, address home)
    {
        return _mimicked(original_, symbol_, name_);
    }

    /**
     * @notice Predict the deterministic mimic address for `name_` under
     *         this instance's stored `(original, symbol)`. Convenience
     *         wrapper around the proto-level {mimicked}; on the
     *         prototype this resolves to the `(native ETH, "1xETH")`
     *         pair.
     */
    function mimicked(string calldata name_) external view returns (bool exists, address home) {
        return _mimicked(original, symbol, name_);
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
        (bool exists, address home) = _mimicked(original, symbol, name_);
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
     * @dev Shared body of both {mimicked} overloads. Derives the maker
     *      address that {coinage} will see for this `(original_,
     *      symbol_)` factory: `address(proto)` for the proto pair, the
     *      predicted clone address otherwise (whether or not the clone
     *      exists). Then asks {coinage} for the deterministic mimic
     *      address that maker would produce for `name_`.
     */
    function _mimicked(Currency original_, string memory symbol_, string memory name_)
        private
        view
        returns (bool exists, address home)
    {
        address maker;
        if (_isProtoPair(original_, symbol_)) {
            maker = address(proto);
        } else {
            bytes32 salt = keccak256(abi.encode(original_, symbol_));
            maker = Clones.predictDeterministicAddress(address(proto), salt, address(proto));
        }
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
