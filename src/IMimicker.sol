// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";

/**
 * @title IMimicker
 * @notice Mimic-token-factory surface of a Mimicry instance. Each clone
 *         (and the prototype itself for the native pair) mints per-name
 *         mimic ERC-20s under its stored `(original, symbol)`. Lets
 *         callers depend on a mimicker without pulling in V4 imports.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
interface IMimicker {
    /**
     * @notice Emitted when this instance mints a fresh mimic via {mimic}.
     * @param  clone The instance that minted the token.
     * @param  token The newly minted mimic ERC-20.
     * @param  name  The name carried by the token.
     */
    event Mimic(address indexed clone, IERC20Metadata indexed token, string name);

    /**
     * @notice The reference token every mimic minted by this instance is
     *         pegged against (`address(0)` for native ETH).
     */
    function original() external view returns (address);

    /**
     * @notice The shared symbol carried by every mimic minted by this
     *         instance.
     */
    function symbol() external view returns (string memory);

    /**
     * @notice Predict the deterministic address of the mimic the clone
     *         for `(original, symbol)` would mint with `name`. Works
     *         whether or not the clone is already deployed.
     */
    function mimicked(address original, string calldata symbol, string calldata name)
        external
        view
        returns (bool exists, address home);

    /**
     * @notice Predict the deterministic mimic address for `name` under
     *         this instance's stored `(original, symbol)`.
     */
    function mimicked(string calldata name) external view returns (bool exists, address home);

    /**
     * @notice Mint a fresh mimic ERC-20 with `name`, this instance's
     *         stored `symbol`, and decimals + supply derived from
     *         `original`. Idempotent — returns the existing mimic if
     *         one with `name` was already minted by this instance.
     */
    function mimic(string calldata name) external returns (IERC20Metadata token);
}
