// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20} from "ierc20/IERC20.sol";

/**
 * @title NeutrinoMaker
 * @notice Lightweight relay cloned per tick range so that each (tickLower,
 *         tickUpper) pair produces a distinct Lepton deployer address — and
 *         therefore a distinct hub token — without consuming the lepton salt.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract NeutrinoMaker {
    /**
     * @notice The Lepton prototype used to mint hub tokens.
     */
    ICoinage public immutable LEPTON;

    /**
     * @param lepton The Lepton prototype (ICoinage).
     */
    constructor(ICoinage lepton) {
        LEPTON = lepton;
    }

    /**
     * @notice Mint a hub token via Lepton and transfer the entire supply to the
     *         caller. Because each clone has a tick-dependent address, Lepton
     *         sees a different deployer per tick range.
     * @param name   Token name.
     * @param symbol Token symbol.
     * @param supply Token supply.
     * @param salt   Lepton salt (free for vanity grinding).
     * @return token The minted hub token.
     */
    function mint(string calldata name, string calldata symbol, uint256 supply, bytes32 salt)
        external
        returns (ICoinage token)
    {
        token = LEPTON.make(name, symbol, supply, salt);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(address(token)).transfer(msg.sender, supply);
    }
}
