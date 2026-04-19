// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IAddressLookup} from "ilookup/IAddressLookup.sol";
import {ICoinage} from "ierc20/ICoinage.sol";
import {IERC20Metadata} from "ierc20/IERC20Metadata.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "v4-periphery/libraries/Actions.sol";
import {ActionConstants} from "v4-periphery/libraries/ActionConstants.sol";

/**
 * @title Mimicoinage
 * @notice Singleton factory that mints an ERC-20 pegged 1:1 against a quote
 *         token and seats its entire supply into a single-tick Uniswap V4
 *         position. The position NFT is minted to the immutable {OWNER}.
 * @dev    The mimic token carries the quote token's decimals so the raw
 *         sqrtPrice of 1 (tick 0) corresponds to a 1:1 human-unit peg.
 *         The pool uses {FEE} = 100 (0.01%), {TICK_SPACING} = 1, and no
 *         hook. Range is `[0, 1)` when the mimic sorts below the quote and
 *         `[-1, 0)` when it sorts above — both place tick 0 at the edge of
 *         the range such that the position holds only the mimic at genesis.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Mimicoinage {
    string public constant VERSION = "0.1.0";

    /**
     * @notice Fixed raw supply minted for every mimic token. Sized to stay
     *         well below the `maxLiquidityPerTick` cap at `TICK_SPACING = 1`
     *         for any reasonable decimals.
     */
    uint128 public constant SUPPLY = 10 ** 27;

    /**
     * @notice Pool fee in hundredths of a bip (0.01%).
     */
    uint24 public constant FEE = 100;

    /**
     * @notice Pool tick spacing — one tick wide for maximum concentration.
     */
    int24 public constant TICK_SPACING = 1;

    /**
     * @notice Symbol suffix appended to the quote token's symbol.
     */
    string public constant SUFFIX = "x1";

    /**
     * @notice The Uniswap V4 PoolManager, resolved from the `IAddressLookup`
     *         supplied at construction.
     */
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice The Uniswap V4 PositionManager, resolved from the
     *         `IAddressLookup` supplied at construction. Mints the position
     *         NFT.
     */
    IPositionManager public immutable POSITION_MANAGER;

    /**
     * @notice The Coinage factory used to mint the mimic ERC-20.
     */
    ICoinage public immutable COINAGE;

    /**
     * @notice Recipient of every mimic position NFT minted by this contract.
     */
    address public immutable OWNER;

    /**
     * @notice Emitted when a mimic token is launched.
     * @param mimic    The newly minted mimic token.
     * @param quote    The quote (reference) token.
     * @param poolId   The Uniswap V4 pool id.
     * @param tokenId  The position NFT id minted to {OWNER}.
     */
    event Launch(IERC20Metadata indexed mimic, IERC20Metadata indexed quote, PoolId indexed poolId, uint256 tokenId);

    /**
     * @notice Thrown if computed liquidity exceeds `uint128`.
     */
    error LiquidityOverflow();

    /**
     * @notice Construct the singleton factory.
     * @param  poolManagerLookup     Lookup for the chain-local PoolManager.
     * @param  positionManagerLookup Lookup for the chain-local PositionManager.
     * @param  coinage               The Coinage factory used to mint mimics.
     * @param  owner                 Recipient of every minted position NFT.
     */
    constructor(
        IAddressLookup poolManagerLookup,
        IAddressLookup positionManagerLookup,
        ICoinage coinage,
        address owner
    ) {
        POOL_MANAGER = IPoolManager(poolManagerLookup.value());
        POSITION_MANAGER = IPositionManager(positionManagerLookup.value());
        COINAGE = coinage;
        OWNER = owner;
    }

    /**
     * @notice Mint a mimic of `quoteToken` and seat its entire supply into a
     *         single-tick V4 position at the 1:1 edge. The position NFT is
     *         minted to {OWNER}.
     * @param  quoteToken The reference token to peg against (read for
     *                    decimals + symbol).
     * @param  name       Name for the newly minted mimic token.
     * @return mimic      The newly minted mimic token.
     */
    function launch(IERC20Metadata quoteToken, string calldata name) external returns (IERC20Metadata mimic) {
        uint8 decimals = quoteToken.decimals();
        string memory symbol = string.concat(quoteToken.symbol(), SUFFIX);
        mimic = COINAGE.make(name, symbol, decimals, SUPPLY, bytes32(0));

        bool mimicIsToken0 = address(mimic) < address(quoteToken);
        int24 tickLower = mimicIsToken0 ? int24(0) : int24(-1);
        int24 tickUpper = mimicIsToken0 ? int24(1) : int24(0);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(mimicIsToken0 ? address(mimic) : address(quoteToken)),
            currency1: Currency.wrap(mimicIsToken0 ? address(quoteToken) : address(mimic)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        POSITION_MANAGER.initializePool(key, TickMath.getSqrtPriceAtTick(0));

        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity =
            mimicIsToken0 ? _liquidity0(sqrtLower, sqrtUpper, SUPPLY) : _liquidity1(sqrtLower, sqrtUpper, SUPPLY);

        // Pre-transfer the mimic supply to PositionManager so the SETTLE
        // action below can pay from PositionManager's own balance instead of
        // routing through permit2.
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        mimic.transfer(address(POSITION_MANAGER), SUPPLY);

        uint256 tokenId = POSITION_MANAGER.nextTokenId();

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            key,
            tickLower,
            tickUpper,
            uint256(liquidity),
            mimicIsToken0 ? SUPPLY : uint128(0),
            mimicIsToken0 ? uint128(0) : SUPPLY,
            OWNER,
            ""
        );
        params[1] = abi.encode(Currency.wrap(address(mimic)), ActionConstants.OPEN_DELTA, false);

        POSITION_MANAGER.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        emit Launch(mimic, quoteToken, key.toId(), tokenId);
    }

    /**
     * @dev Liquidity for a single-sided position in currency0.
     *      L = amount0 * (sqrtLower * sqrtUpper / Q96) / (sqrtUpper - sqrtLower)
     */
    function _liquidity0(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount0) private pure returns (uint128) {
        uint256 intermediate = FullMath.mulDiv(uint256(sqrtLower), uint256(sqrtUpper), FixedPoint96.Q96);
        return _toUint128(FullMath.mulDiv(amount0, intermediate, uint256(sqrtUpper - sqrtLower)));
    }

    /**
     * @dev Liquidity for a single-sided position in currency1.
     *      L = amount1 * Q96 / (sqrtUpper - sqrtLower)
     */
    function _liquidity1(uint160 sqrtLower, uint160 sqrtUpper, uint256 amount1) private pure returns (uint128) {
        return _toUint128(FullMath.mulDiv(amount1, FixedPoint96.Q96, uint256(sqrtUpper - sqrtLower)));
    }

    function _toUint128(uint256 x) private pure returns (uint128) {
        if (x > type(uint128).max) revert LiquidityOverflow();
        // safe: bounds checked on the line above.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(x);
    }
}
