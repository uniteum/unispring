// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Clones} from "clones/Clones.sol";
import {Fountain} from "./Fountain.sol";
import {IERC20} from "ierc20/IERC20.sol";
import {Currency} from "v4-core/types/Currency.sol";

/**
 * @title Unispring
 * @notice Clone-per-hub factory that seats fair-launch pools on {FOUNTAIN}.
 *         Each clone owns a single hub token and pairs it against spokes
 *         supplied by callers. The hub's own ETH pool is seated single-sided
 *         by {zzInit}; spoke pools are seated single-sided by {fund}.
 * @dev    All V4 plumbing — unlock, modifyLiquidity, liquidity math, fee
 *         take — lives on {FOUNTAIN}. Unispring only mints/tracks
 *         the clone-per-hub key, pre-approves {FOUNTAIN} against pulled
 *         tokens, and delegates to {Fountain.offer}. Pools inherit
 *         {Fountain.FEE} (0.01%) and accrued fees flow to Fountain's owner.
 * @dev    Ticks: callers pass V4-native `(tickLower, tickUpper)` in the
 *         log_1.0001(currency1/currency0) convention. For the hub pool the
 *         hub sorts above ETH (currency1), so Unispring translates into
 *         Fountain's log(quote/token) user-tick semantics by negating and
 *         swapping; spoke pools (spoke sorts below hub as currency0) pass
 *         through identity. Either way, the V4 position is seated at
 *         `[tickLower, tickUpper]` in V4-native terms. (V4's active-
 *         liquidity check uses the half-open convention
 *         `tickLower <= currentTick < tickUpper`; its token-composition
 *         check is closed on both ends. See README §Token ordering.)
 * @dev    Pure factory. Once {fund} settles, the position is permanent and
 *         this contract has no authority to unwind it or modify the pool —
 *         no owner, no upgrade path, no admin keys. All post-launch swap
 *         behavior belongs to the Uniswap V4 PoolManager and whatever DEX
 *         routers reach the pool. See README §Trust boundaries.
 * @author Paul Reinholdtsen (reinholdtsen.eth)
 */
contract Unispring {
    string public constant VERSION = "0.2.0";

    /**
     * @notice The prototype instance that acts as the Bitsy factory.
     */
    Unispring public immutable PROTO;

    /**
     * @notice The Fountain that seats and owns every position funded through
     *         this Unispring. Positions inherit {Fountain.POOL_MANAGER} and
     *         {Fountain.FEE}; accrued fees flow to `FOUNTAIN.owner()`.
     */
    Fountain public immutable FOUNTAIN;

    /**
     * @notice The hub token, set by {zzInit} on each clone.
     * @dev    The full hub supply must be transferred to the clone's
     *         deterministic address (from {made}) before {make} is called;
     *         {zzInit} reads `hub.balanceOf(this)` as the amount to fund.
     *         See DESIGN.md §8 for the salt-mining rationale.
     */
    address public hub;

    /**
     * @notice Emitted when a new clone is created via {make}.
     */
    event Make(Unispring indexed clone, IERC20 indexed hub, int24 tickLower, int24 tickUpper);

    /**
     * @notice Emitted when a pool is initialized, paired against the hub (or
     *         ETH for the hub pool itself), and funded.
     * @param funder     The address that called {fund}. Equals this clone's
     *                   own address on the hub-pool seed call from {zzInit}.
     * @param token      The spoke currency (or the hub, for {zzInit}).
     *                   `Currency.wrap(address(0))` for a native-ETH spoke.
     * @param positionId The {FOUNTAIN} position id seated by this call.
     * @param supply     The fixed supply funded into the pool.
     * @param tickLower  V4-native lower tick of the funded position.
     * @param tickUpper  V4-native upper tick of the funded position.
     */
    event Funded(
        address indexed funder,
        Currency indexed token,
        uint256 indexed positionId,
        uint256 supply,
        int24 tickLower,
        int24 tickUpper
    );

    /**
     * @notice Thrown when `tickLower` is not strictly below `tickUpper`.
     */
    error TickLowerNotBelowUpper(int24 tickLower, int24 tickUpper);

    /**
     * @notice Thrown when the spoke token does not sort strictly below {hub}.
     * @dev    Only applies to ERC-20 spokes; a native-ETH spoke
     *         (`address(0)`) always sorts below {hub}. For ERC-20 spokes,
     *         mine a different spoke salt until the deterministic address
     *         sorts below {hub}. See DESIGN.md §6 for why the ordering is
     *         required.
     */
    error SpokeMustSortBelowHub(address token);

    /**
     * @notice Thrown when {zzInit} is called by anyone other than {PROTO}.
     */
    error Unauthorized();

    /**
     * @notice Construct the prototype. Clones are created via {make}.
     * @param  fountain The Fountain that will seat every position funded
     *                  through this Unispring.
     */
    constructor(Fountain fountain) {
        PROTO = this;
        FOUNTAIN = fountain;
    }

    // ---- Bitsy factory ----

    /**
     * @notice Predict the deterministic address of a clone.
     * @return exists True if the clone is already deployed.
     * @return home   The deterministic clone address.
     * @return salt   The CREATE2 salt.
     */
    function made(IERC20 hub_, int24 tickLower, int24 tickUpper)
        public
        view
        returns (bool exists, address home, bytes32 salt)
    {
        salt = keccak256(abi.encode(hub_, tickLower, tickUpper));
        home = Clones.predictDeterministicAddress(address(PROTO), salt, address(PROTO));
        exists = home.code.length > 0;
    }

    /**
     * @notice Deploy a deterministic clone for the given hub and tick range.
     *         Idempotent — returns the existing clone if already deployed.
     * @return clone The deployed (or existing) clone.
     */
    function make(IERC20 hub_, int24 tickLower, int24 tickUpper) external returns (Unispring clone) {
        if (address(this) != address(PROTO)) {
            clone = PROTO.make(hub_, tickLower, tickUpper);
        } else {
            (bool exists, address home, bytes32 salt) = made(hub_, tickLower, tickUpper);
            clone = Unispring(home);
            if (!exists) {
                Clones.cloneDeterministic(address(PROTO), salt, 0);
                Unispring(home).zzInit(hub_, tickLower, tickUpper);
                emit Make(clone, hub_, tickLower, tickUpper);
            }
        }
    }

    /**
     * @notice Initializer for a freshly deployed clone. Sets {hub}, initializes
     *         the hub's ETH pool, and funds it single-sided with the hub
     *         balance held at this address. Callable only by {PROTO}.
     * @dev    See DESIGN.md §7 for the mirror-geometry rationale (the position
     *         is inactive at spot until a bootstrap ETH→hub swap crosses
     *         `tickUpper` downward) and §11 for the `this.fund` idiom.
     */
    function zzInit(IERC20 hub_, int24 tickLower, int24 tickUpper) external {
        if (msg.sender != address(PROTO)) revert Unauthorized();
        hub = address(hub_);
        uint256 supply = hub_.balanceOf(address(this));
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        hub_.approve(address(this), supply);
        this.fund(Currency.wrap(address(hub_)), supply, tickLower, tickUpper);
    }

    /**
     * @notice Lock `supply` of `token` into a single-sided V4 position paired
     *         against {hub} (or ETH when `token` is the hub). Permissionless —
     *         anyone can pair any currency, any number of times.
     * @dev    Spokes must sort strictly below {hub} (become `currency0`); a
     *         native-ETH spoke (`Currency.wrap(address(0))`) always satisfies
     *         this. For ERC-20 spokes the caller must approve this contract
     *         for `supply` tokens; for a native-ETH spoke the caller must
     *         send `supply` as `msg.value`. See DESIGN.md §9 for the
     *         permissionless + re-call semantics, §10 for the spoke-isolation
     *         argument, and README §Patterns for common re-funding use cases.
     * @param  token      The currency to pair. The hub itself pairs against ETH;
     *                    any other currency pairs against {hub}.
     * @param  supply     Amount of `token` to lock. Pulled from the caller
     *                    via `transferFrom` for ERC-20s; must arrive as
     *                    `msg.value` for a native-ETH spoke.
     * @param  tickLower  V4-native lower tick; strictly below `tickUpper`.
     * @param  tickUpper  V4-native upper tick.
     * @return positionId The {FOUNTAIN} position id seated by this call.
     */
    function fund(Currency token, uint256 supply, int24 tickLower, int24 tickUpper)
        external
        payable
        returns (uint256 positionId)
    {
        if (tickLower >= tickUpper) revert TickLowerNotBelowUpper(tickLower, tickUpper);

        address tokenAddr = Currency.unwrap(token);
        bool isHub = tokenAddr == hub;
        if (!isHub && tokenAddr >= hub) revert SpokeMustSortBelowHub(tokenAddr);

        if (!token.isAddressZero()) {
            IERC20 erc = IERC20(tokenAddr);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            erc.transferFrom(msg.sender, address(this), supply);
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            erc.approve(address(FOUNTAIN), supply);
        }

        int24[] memory ticks = new int24[](2);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = supply;
        Currency quote;
        if (isHub) {
            // Hub sorts above ETH (currency1). Fountain takes ticks in
            // log(quote/token) semantics and negates for the flip case;
            // negate-and-swap here to preserve Unispring's V4-native range.
            ticks[0] = -tickUpper;
            ticks[1] = -tickLower;
            quote = Currency.wrap(address(0));
        } else {
            // Spoke sorts below hub (currency0): identity mapping.
            ticks[0] = tickLower;
            ticks[1] = tickUpper;
            quote = Currency.wrap(hub);
        }

        positionId = FOUNTAIN.offer{value: msg.value}(token, quote, 1, ticks, amounts);
        emit Funded(msg.sender, token, positionId, supply, tickLower, tickUpper);
    }
}
