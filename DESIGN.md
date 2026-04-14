# Unispring — design rationale

A walkthrough of the deliberate choices in [src/Unispring.sol](src/Unispring.sol),
written so a new reader can open the contract and understand *why* each piece
is the way it is, not just what it does. Companion document to [CRITIQUE.md](CRITIQUE.md)
(open questions and concerns) and [README.md](README.md) (high-level pitch).

---

## 1. Direct `IPoolManager` calls instead of v4-periphery

**Choice.** Unispring inherits `IUnlockCallback` and talks to the `PoolManager`
directly. It does *not* use `v4-periphery`'s `PositionManager`, `Router`, or
`LiquidityAmounts` library.

**Why.** The contract's core invariant is *the liquidity is owned by nobody*.
`PositionManager` wraps every position as an ERC-721: whoever holds the NFT
can transfer it, withdraw, or collect fees. If Unispring used `PositionManager`,
the contract would nominally *own* each position NFT and would have to
implement custody logic — defeating the "locked forever" guarantee at the
social level, even if the code never exposed the NFT.

Calling `PoolManager.modifyLiquidity` directly from inside the unlock callback
creates a position keyed by `(owner=Unispring, tickLower, tickUpper, salt=0)`
with no NFT, no transfer path, and no collect function that anyone else can
reach. The permanence is enforced at the lowest level.

**Cost.** Unispring has to do the unlock / sync / settle choreography itself.
That's what `_seed`, `_plow`, `_buyHub`, and `_settleOwed` are. It also
reimplements the three standard concentrated-liquidity formulas
(`_liquidityForAmount0`, `_liquidityForAmount1`, `_liquidityForAmounts`)
instead of importing `LiquidityAmounts` from periphery. The math is short
and standard; the dependency isn't worth adding for ~40 lines.

---

## 2. Unispring is stateless

**Choice.** The contract has no mutable storage. Everything is immutable
(`POOL_MANAGER`, `HUB`, `HUB_TICK_FLOOR`) or recomputed from the PoolManager.

**Why.** Earlier drafts kept `hubPool`, `poolToken[PoolId]`, and
`floor[address]` mappings to track "which pools exist" and "what tick range
does this pool use." Every one of those was a duplicate of information
already recoverable from the `PoolManager`:

- *Does this pool exist?* → `PoolManager.initialize` reverts with
  `PoolAlreadyInitialized` on a re-init attempt.
- *What's the tick range of Unispring's position?* → caller supplies it;
  Unispring verifies via `StateLibrary.getPositionInfo` that a non-zero
  liquidity position exists at that range.

Removing the state eliminated two subtle problems: (a) a shared namespace
between the `HUB` address and spoke addresses in a single `address => int24`
mapping, and (b) a `floor[token] == 0` ambiguity that conflated "never
registered" with "registered with `tickFloor == 0`."

**Cost.** `plow` now takes `(PoolKey key, int24 tickLower, int24 tickUpper)`
instead of just a token address. Callers recover the tick range from the
`Seeded` event, from convention (hub → `[minUsableTick, -HUB_TICK_FLOOR]`;
spoke → `[tickFloor, maxUsableTick]`), or from the deploy artifacts.

---

## 3. Hub-and-spoke pool topology

**Choice.** Every token Unispring seeds is paired against a single `HUB`
token. The hub is paired against native ETH. Spokes are never paired against
each other.

**Why.** Forces a single liquidity graph. An aggregator that routes
`ETH → spokeA → spokeB` will always go `ETH → HUB → spokeA → spokeB`, and
because every pool sits at the same fee tier and on the same canonical
structure, discovery is trivial. Compare this to the default situation where
tokens fragment across arbitrary pairings — liquidity splits across `A/ETH`,
`A/USDC`, `A/B` pools, and no single venue has the full depth.

**Cost.** The hub becomes a single point of dependency. Its reputation is
hostage to every spoke that registers against it (see CRITIQUE concern 1 for
the Lepton-launcher mitigation).

---

## 4. 0.01% single fee tier

**Choice.** `FEE = 100` (0.01%), `TICK_SPACING = 1`, for every pool Unispring
creates.

**Why.** One of the canonical Uniswap fee tiers, so every SOR enumerates it
on fallback. Keeps routed trades cheap: `ETH → HUB → spoke` pays 0.02% total,
competitive with any single-hop venue. Tick spacing 1 gives maximum
granularity at the floor boundary, so the floor lands exactly where the
deployer specified rather than being rounded to a coarse grid.

**Cost.** Slowest possible moat growth. Fees compound via `plow`, and at
0.01% a pool needs roughly 10,000× its current depth in cumulative volume
to double itself. That's a multi-year horizon. Unispring accepts this trade
because it optimizes for *survival* (be discoverable, routable, cheap to
swap) over *thickening speed*. Projects that want faster compounding can
bypass Unispring and call `PoolManager` directly with a higher fee tier — V4
is the substrate, Unispring is one recipe on top of it.

---

## 5. Single-sided seed at the tick floor

**Choice.** Seed positions are single-sided in the token being seeded, with
tick range `[tickFloor, maxUsableTick]` for spokes and the mirror
`[minUsableTick, -HUB_TICK_FLOOR]` for the hub. The pool's initial price
sits at the lower bound of the spoke range (so spokes are *active* at spot)
and at the upper bound of the hub range (so the hub starts *inactive* until
the bootstrap swap crosses it).

**Why.** Three properties fall out of this geometry:

1. **Permanent floor.** The position sits entirely above `tickFloor`. The
   pool price literally cannot drop below the floor without crossing an
   empty tick range, which V4's concentrated liquidity math forbids.
2. **Zero hub capital required.** A single-sided spoke position at the
   lower boundary of its range needs only `currency0` — the spoke token —
   and zero of `currency1` (HUB). The deployer never has to pre-buy HUB
   to seed a spoke.
3. **Fair launch.** All of the seeded supply becomes locked liquidity at or
   above the floor. The deployer can't keep a hidden bag: whatever they
   transfer into Unispring becomes permanent liquidity that anyone can buy.

**Cost.** The spoke token must sort strictly below HUB (it must become
`currency0`), which is enforced at `addSpoke` via the `SpokeMustSortBelowHub`
check. See choice 7 below.

---

## 6. Hub seeded in the "mirror" case

**Choice.** The hub pool is seeded single-sided in HUB (currency1), with
range `[minUsableTick, -HUB_TICK_FLOOR]`, initial price at the upper bound.
This is the mirror image of a spoke seed: the position is *inactive at spot*
until something crosses the upper tick downward.

**Why.** ETH is always `currency0` (address zero sorts below any real
address). The natural "spoke-like" seed would be single-sided in ETH, but
that requires the seeder to hold ETH at launch time. Unispring's deploy
flow has HUB tokens, not ETH. Flipping the geometry lets the seeder use
only the asset they have.

The side effect is that immediately after `seedHub`, the pool's displayed
price is the upper tick boundary and the position is inactive — quoters
see "no liquidity at spot" and refuse to route. A bootstrap swap (via
`buyHub`) crosses the tick downward and flips the pool into a normal
active state.

**Cost.** The hub bootstrap is a two-step dance: `seedHub` then `buyHub`.
Between those two transactions, the pool exists but looks dead. A single
deploy script handles both calls back-to-back, but anyone racing in sees
a confusing state. See CRITIQUE concern 2.

---

## 7. Salt-mined hub address with leading `f` bytes

**Choice.** The hub token is deployed at a vanity address with several
leading `f` bytes (e.g. `0xffff...`).

**Why.** V4 requires `currency0 < currency1` in every PoolKey. For the
single-sided-at-lower-bound seed math to work, spokes must become
`currency0`, which means every spoke address must sort strictly below the
hub address. A hub starting with `f...` means almost every possible spoke
address sorts below it without needing to mine the spoke address at all.

This also stabilizes the single-sided seed formula. If spoke/hub sides were
swapped case-by-case, `addSpoke` would need branching logic to figure out
which side to fund and which tick boundary to seed at. With enforced
ordering, there's exactly one formula for spokes and it lives in `_seed`
without any currency-side branch.

**Cost.** The hub can't be an arbitrary existing ERC-20. It has to be
deployed (or chosen) to satisfy the address constraint. In practice the
hub is minted specifically for Unispring, so this is a one-time deploy
cost, not an ongoing constraint.

---

## 8. Permissionless `plow` with no reward

**Choice.** Anyone can call `plow` at any time. There's no operator role,
no caller reward, no treasury cut. The function is strictly
altruistic-or-aligned: the caller pays gas to compound the position's fees
back into itself.

**Why.** Any reward mechanism creates a second token-flow to reason about
and a second trust surface. No reward means no extraction: every unit of
compounded fee stays in the locked position, and the caller's only
incentive is wanting the token's depth to grow (holders, the project
itself, bots with an interest in the token). The contract has no opinion
on *who* calls `plow` or *how often*.

**Cost.** `plow` only runs when someone decides to pay for it. A neglected
spoke accumulates fees that sit un-compounded until someone cares enough
to call. That's acceptable because the fees don't leak — they stay in the
pool, and the next caller captures them all at once.

---

## 9. `HUB_TICK_FLOOR` is immutable

**Choice.** The hub's price floor is set at construction and can never
change.

**Why.** Immutable governance surface. There is literally no function that
can adjust the floor, no admin role, no upgrade path, no multisig. The
floor is a property of the deployment, not a parameter anyone can touch
later. Front-ends and integrators can cache it forever.

**Cost.** A bad floor choice at deployment time is permanent. Mitigation:
deploy scripts compute the floor from the hub's intended starting price
and current ETH price, and the deployer can verify on testnet before
mainnet. No ongoing maintenance; a wrong floor means redeploying a fresh
Unispring.

---

## 10. Two-step deploy (constructor + `seedHub`)

**Choice.** The constructor does *not* seed the hub pool. Seeding is
deferred to a separate `seedHub` call that the deploy script makes
immediately after construction.

**Why.** Pool seeding goes through `PoolManager.unlock`, which calls back
into `unlockCallback` on the caller. During a contract's own constructor,
the runtime code isn't deployed yet — the callback would land on an
address with no code and revert. Deferring seeding to a regular external
call gives the callback something to land on.

**Cost.** The deploy script has to make two transactions (deploy, then
`seedHub`), and there's a brief window between them where Unispring holds
the full hub supply but the pool isn't initialized. The deploy script
handles both in sequence under one broadcaster, so the window is only
observable if someone is watching mempool.

---

## 11. Unlock callback dispatches on an `Action` enum

**Choice.** `unlockCallback` decodes a `(Action, bytes)` tuple and
dispatches to `_seed`, `_plow`, or `_buyHub`. Each caller (`seedHub`,
`addSpoke`, `plow`, `buyHub`) encodes its own action and payload before
calling `POOL_MANAGER.unlock`.

**Why.** V4 gives you exactly one `unlockCallback` per contract. Unispring
has three operations that need the unlock context (seed a position,
compound an existing position, execute the bootstrap swap). The cleanest
way to multiplex them is a tagged union in the callback payload. The enum
makes the dispatch explicit and the ABI-encoded inner payload keeps each
operation's data isolated.

**Cost.** One extra layer of `abi.encode` / `abi.decode` per operation,
and the reader has to follow the indirection from the external entry
point through `unlock` → `unlockCallback` → `_seed`/`_plow`/`_buyHub`.
The alternative (separate callback contracts per operation) would be more
code and more deployment artifacts.

---

## 12. Seeded event semantics

**Choice.** The `Seeded` event emits `(seeder, token, poolId, supply, tickFloor)`.
`tickFloor` is always the caller-facing floor value (positive for spokes,
positive for the hub), not the pool's raw `tickLower`.

**Why.** Off-chain consumers need the floor in *spoke-priced-in-counterparty*
semantics, which is how humans think about "the lowest price this token can
ever trade at." Emitting the raw `tickLower` (which is negative for the hub
pool because of the mirror geometry) would force every indexer to know about
the mirror case and flip the sign. Keeping the event's `tickFloor` in human
semantics means one indexer formula works for both hub and spokes.

---

## Non-goals

Things Unispring deliberately does **not** try to do:

- **Multiple fee tiers per spoke.** Opinionated simplicity. See choice 4.
- **Custom hooks.** The `hooks` field in every Unispring PoolKey is
  `address(0)`. Adding hook support would fragment the liquidity graph and
  re-open the "which pool is canonical for this pair" question.
- **Governance.** No owner, no admin, no upgrade. The only mutable behavior
  in the system is `plow`, which is deterministic and permissionless.
- **Fee to treasury or LP rewards.** No skimming. Every fee plowed goes
  back into the locked position.
- **Withdraw / unwind path.** The position is permanent. There is no
  function to remove liquidity.
- **Governance over floor, supply, or fee.** All frozen at deploy.

Unispring is a single opinionated recipe. Projects that want something
different use V4 directly.
