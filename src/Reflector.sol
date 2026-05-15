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
 * @notice Mints 1:1 mirror ERC-20s for any reference asset (native
 * ETH or any ERC-20). A buyer pays one unit of the reference
 * to mint one unit of the mirror, and a seller does the
 * reverse. Used to create "1xETH"-style wrappers.
 * @dev Two-level factory. The prototype mints clones keyed by
 * `(peg, symbol)`; each clone mints ERC-20s keyed by `name`.
 * The full mirror supply is locked into a single-tick V4
 * pool at price 1, so the pool itself is the mint/burn
 * mechanism. The prototype doubles as the clone for the
 * native-ETH pair — its symbol is `"1x<native>"` resolved
 * at construction from a chain-local symbol lookup
 * ("1xETH" on mainnet, "1xMATIC" on Polygon).
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Reflector is IReflectorMaker, IReflector, Prototype {
    string public constant version = "0.9.0";

    /**
     * @notice Supply for an 18-decimal issue.
     * @dev Supply scales down with fewer decimals to keep the displayed supply roughly constant.
     *
     * Supply must be less than `maxLiquidityPerTick` at `tickSpacing = 1`.
     */
    uint128 public constant maxSupply = 10 ** 27;

    /**
     * @notice Holds the liquidity for each token issued through this Reflector.
     */
    IPlacer public immutable placer;

    /**
     * @notice The token factory used to issue mirror tokens.
     */
    ICoinage public immutable coinage;

    /**
     * @inheritdoc IReflector
     */
    address public peg;

    /**
     * @inheritdoc IReflector
     */
    string public symbol;

    /**
     * @notice Deploy the prototype, which doubles as the factory for
     * the native-ETH pair. Its symbol is `"1x<native>"`,
     * resolved from {gasSymbolLookup} at construction. Clones
     * for other peg/symbol pairs are created via {make}.
     * @param placer_ Holds the liquidity for each token issued
     * through this Reflector.
     * @param minter The Coinage prototype used to mint issues.
     * @param gasSymbolLookup Chain-local {IStringLookup} whose `value()`
     * returns the native currency symbol (e.g. "ETH" on mainnet,
     * "MATIC" on Polygon); used as the suffix for the prototype's
     * issue symbol `"1x<native>"`.
     */
    constructor(IPlacer placer_, ICoinage minter, IStringLookup gasSymbolLookup) {
        placer = placer_;
        coinage = minter;
        symbol = string.concat("1x", gasSymbolLookup.value());
        emit Make(address(this), address(0), symbol);
    }

    /**
     * @inheritdoc IReflector
     */
    function issued(string calldata name_, uint256 variant) external view returns (bool exists, address home) {
        return _issued(peg, symbol, name_, variant);
    }

    /**
     * @inheritdoc IReflector
     */
    function issue(string calldata name_, uint256 variant) external returns (address token) {
        address peg_ = peg;
        (bool exists, address home) = _issued(peg_, symbol, name_, variant);
        if (exists) return home;

        (uint8 decimals, uint256 supply) = _issueMetadata(peg_);
        IERC20Metadata issued_ = coinage.make(name_, symbol, decimals, supply, variant);
        token = address(issued_);

        // coinage mints the uniteum ERC-20 port, whose approve cannot fail or return false.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        issued_.approve(address(placer), supply);

        int24[] memory ticks = new int24[](2);
        ticks[0] = 0;
        ticks[1] = 1;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = supply;

        placer.offer(token, peg_, ticks, amounts);

        emit Issue(address(this), token, name_);
    }

    /**
     * @inheritdoc IReflectorMaker
     */
    function made(address peg_, string calldata symbol_, uint256 variant)
        external
        view
        returns (bool exists, address home, bytes32 salt)
    {
        if (_isProtoPair(_resolve(peg_), symbol_)) {
            return (true, proto, bytes32(0));
        }
        (exists, home, salt) = this.made(encode(peg_, symbol_), variant);
    }

    /**
     * @inheritdoc IReflectorMaker
     */
    function make(address peg_, string calldata symbol_, uint256 variant) external returns (address clone) {
        address resolved = _resolve(peg_);
        if (_isProtoPair(resolved, symbol_)) {
            clone = proto;
        } else {
            (bool exists, address home,) = this.make(encode(peg_, symbol_), variant);
            clone = home;
            if (!exists) emit Make(home, resolved, symbol_);
        }
    }

    /**
     * @inheritdoc IPrototype
     * @dev Decodes `(peg_, symbol_)`, resolves any {IAddressLookup} to
     * its underlying address, and records the pair on the clone.
     * Reverts if the args encode the proto pair so the prototype
     * remains the sole canonical factory for `(native ETH, proto.symbol())`
     * even when callers bypass the typed wrappers.
     */
    function zzInit(bytes calldata args, uint256) external override onlyProto {
        (address peg_, string memory symbol_) = abi.decode(args, (address, string));
        peg_ = _resolve(peg_);
        if (_isProtoPair(peg_, symbol_)) revert ProtoPairReserved();
        peg = peg_;
        symbol = symbol_;
    }

    /**
     * @notice ABI-encode the per-clone init args.
     */
    function encode(address peg_, string memory symbol_) public pure returns (bytes memory args) {
        args = abi.encode(peg_, symbol_);
    }

    /**
     * @dev Ask {coinage} for the deterministic issue address this
     * instance would produce for `(name_, symbol_, variant)` with
     * metadata derived from `peg_`.
     */
    function _issued(address peg_, string memory symbol_, string memory name_, uint256 variant)
        private
        view
        returns (bool exists, address home)
    {
        (uint8 decimals, uint256 supply) = _issueMetadata(peg_);
        (exists, home,) = coinage.made(address(this), name_, symbol_, decimals, supply, variant);
    }

    /**
     * @dev Resolve `peg_` into the underlying token address.
     * `address(0)` is native ETH; an {IAddressLookup} resolves to
     * its `value()`; any other deployed address is treated as the
     * token itself. Reverts with {UnmappedLookup} when `peg_` has
     * no code (an undeployed lookup or stray EOA would otherwise
     * be silently stored as the peg), or when an
     * {IAddressLookup}'s `value()` returns `address(0)`.
     */
    function _resolve(address peg_) private view returns (address) {
        if (peg_ == address(0)) return address(0);
        if (peg_.code.length == 0) revert UnmappedLookup(peg_);
        try IAddressLookup(peg_).value() returns (address resolved) {
            if (resolved == address(0)) revert UnmappedLookup(peg_);
            return resolved;
        } catch {
            return peg_;
        }
    }

    /**
     * @dev Decimals and supply to mint against `peg_`. Native ETH: 18
     * and {maxSupply}. ERC-20: peg's decimals, and {maxSupply}
     * scaled down by 10 per decimal under 18 — kept below
     * `maxLiquidityPerTick` for a single-sided one-tick seat.
     */
    function _issueMetadata(address peg_) private view returns (uint8 decimals, uint256 supply) {
        if (peg_ == address(0)) return (18, maxSupply);
        decimals = IERC20Metadata(peg_).decimals();
        supply = uint256(maxSupply);
        if (decimals < 18) supply /= 10 ** uint256(18 - decimals);
    }

    /**
     * @dev True when `(peg_, symbol_)` is the prototype's own pair
     * `(native ETH, proto.symbol())`, i.e. the pair for which the
     * prototype itself is the factory.
     */
    function _isProtoPair(address peg_, string memory symbol_) private view returns (bool) {
        return peg_ == address(0) && keccak256(bytes(symbol_)) == keccak256(bytes(Reflector(proto).symbol()));
    }
}
