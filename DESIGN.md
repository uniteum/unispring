# Unispring — design rationale

A walkthrough of the deliberate choices in [src/Unispring.sol](src/Unispring.sol),
written so a new reader can open the contract and understand *why* each piece
is the way it is, not just what it does. Companion document to
[CRITIQUE.md](CRITIQUE.md) (open questions and concerns) and
[README.md](README.md) (high-level pitch and use-case patterns).

---

## 1. Direct `IPoolManager` calls instead of v4-periphery

**Choice.** Unispring inherits `IUnlockCallback` and talks to the
`PoolManager` directly. No `v4-periphery`, no `PositionManager`, no
`LiquidityAmounts`.

**Why.** The core invariant is *the liquidity is owned by nobody*.
`PositionManager` wraps each position as an ERC-721: whoever holds the NFT
can transfer it, withdraw, or collect fees. Going through periphery would
mean Unispring nominally *owns* NFTs and has to implement custody, which
defeats the "locked forever" guarantee socially even if code never exposes
the token.

Calling `PoolManager.modifyLiquidity` from inside `unlockCallback` creates a
position keyed by `(owner = clone, tickLower, tickUpper, salt = 0)` with no
NFT, no transfer path, and no collect function anyone else can reach.
Permanence enforced at the lowest level.

**Cost.** The unlock / sync / settle choreography lives inline in
`unlockCallback`, and `_liquidity0` / `_liquidity1` reimplement the two
single-sided concentrated-liquidity formulas. About twenty lines of math;
the dependency isn't worth it.

---

## 2. Bitsy factory: PROTO + per-range clones

**Choice.** A single `PROTO` contract per chain holds all the logic. Each
`(hub, tickLower, tickUpper)` triple gets its own EIP-1167 minimal proxy
clone, deployed CREATE2 by `make`. The clone's future address is
deterministic from the triple and returned by `made` before deploy.

**Why.** Three properties compose:

1. **Pre-addressable.** Deploy scripts pre-fund the clone's future address
   *before* calling `make`. `zzInit` reads `hub.balanceOf(address(this))`
   as the amount to seed, so the hub supply must already sit at the clone's
   predicted home. No approval dance, no front-running window.
2. **Idempotent.** `make` checks `home.code.length > 0` and returns the
   existing clone if already deployed. Safe to call from multiple
   pipelines.
3. **Per-range isolation.** The same hub can back multiple clones at
   different tick ranges — useful if a deployment needs to be retried with
   a corrected range without disturbing the original. Clones never share
   state.

**Cost.** `PROTO` must be deployed once per chain. Each clone adds the
~45-byte EIP-1167 proxy bytecode plus one `zzInit` setup.

---

## 3. Minimal state per clone

**Choice.** Each clone stores exactly one mutable variable: `hub` (address),
set once by `zzInit`. Everything else is immutable (`PROTO`, `POOL_MANAGER`,
`FEE`) or recovered from the PoolManager on demand.

**Why.** Earlier drafts kept `hubPool`, `poolToken[PoolId]`, and
`floor[address]` mappings to track "which pools exist" and "what range does
this pool use." All of that duplicated state the PoolManager already owns:

- Does the pool exist? — `getSlot0` returns `sqrtPriceX96 == 0` for
  uninitialized pools; `fund` uses that to decide whether to call
  `initialize`.
- What tick range? — caller supplies it at every `fund`. Positions are
  keyed by `(owner, tickLower, tickUpper, salt)` in the PoolManager, so
  the PoolManager is the authoritative store.

Removing that mapping state killed two ambiguities: mixing the hub address
into the same mapping as spokes, and a `floor[token] == 0` value that
conflated "unregistered" with "registered with floor 0."

**Cost.** Callers must remember their own tick range across multiple `fund`
calls on the same pool. The `Funded` event carries it for indexers.

---

## 4. Hub-and-spoke pool topology

**Choice.** Every token Unispring funds is paired against the clone's single
hub token. The hub is paired against native ETH. Spokes are never paired
against each other.

**Why.** Forces a single liquidity graph. An aggregator routing
`ETH → spokeA → spokeB` always goes `ETH → hub → spokeA → spokeB`, and
because every Unispring pool sits at the same fee tier and the same
canonical structure, discovery is trivial. Compare this to the default
situation where tokens fragment across arbitrary pairings — liquidity
splits across `A/ETH`, `A/USDC`, `A/B` pools, and no single venue has full
depth.

**Cost.** The hub is a single point of dependency. Its reputation is
hostage to every spoke that registers against it (see CRITIQUE concern 1
for the Lepton-launcher mitigation).

---

## 5. Zero-fee pools, `tickSpacing = 1`

**Choice.** `FEE = 0` and `tickSpacing = 1` for every pool.

**Why.** No fees means no fee-compounding machinery — no plow, no reward
dilemma, no operator role. The position's value is exactly the supply that
funded it; it doesn't drift upward by accumulation. When a pool grows, it
grows because someone calls `fund` again (see README §Patterns), not
because of internal skimming.

Zero-fee swaps are the cheapest possible route through a Unispring pool —
an aggregator routing `ETH → hub → spoke` pays zero at both hops. Tick
spacing 1 gives maximum granularity at the floor, so a caller-supplied
tick lands exactly where specified rather than being rounded to a coarse
grid.

**Cost.** No native moat growth. A spoke that no one adds to stays at its
initial depth forever. Projects that want fee compounding call the
PoolManager directly with a higher-fee tier — V4 is the substrate,
Unispring is one recipe on top of it.

---

## 6. Single-sided seed at the tick floor (spoke geometry)

**Choice.** Spoke positions are single-sided in the spoke token (currency0),
with range `[tickLower, tickUpper]` supplied by the caller. The pool's
initial price sits at `tickLower`, so the position is *active at spot* —
the first buyer begins consuming spoke supply immediately.

**Why.** Three properties fall out of this geometry:

1. **Permanent floor.** The position sits entirely above `tickLower`. The
   pool price literally cannot drop below `tickLower` without crossing an
   empty tick range, which V4's concentrated-liquidity math forbids.
2. **Zero hub capital required.** A single-sided currency0 position at the
   lower boundary of its range needs only `currency0` (spoke) — zero hub.
   The funder never has to pre-buy hub to seed a spoke.
3. **Fair launch.** All of the seeded supply becomes locked liquidity at or
   above the floor. The funder can't retain a hidden bag: whatever they
   transferred into the clone becomes permanent liquidity anyone can buy.

**Cost.** The spoke token must sort strictly below the hub (it must become
`currency0`), enforced by `SpokeMustSortBelowHub`. See §8.

---

## 7. Hub seeded in the mirror case

**Choice.** The hub/ETH pool is seeded by `zzInit` single-sided in hub
(currency1), with range `[tickLower, tickUpper]` passed by the deploy
script, initial price at `tickUpper`. This is the mirror image of a spoke
seed: the position is *inactive at spot* until an ETH → hub swap crosses
`tickUpper` downward.

**Why.** ETH is always `currency0` (address zero sorts below any real
address). The natural "spoke-like" seed would be single-sided in ETH, but
that requires the seeder to hold ETH at launch time, and the deploy flow
holds hub tokens, not ETH. Flipping the geometry lets `zzInit` seed with
only the asset the clone actually holds.

**Cost.** Between `zzInit` and the first bootstrap swap the pool exists
but looks dead — quoters see "no liquidity at spot" and refuse to route.
Deploy pipelines fire the bootstrap ETH → hub swap back-to-back with
`make`; anyone racing in before that swap lands sees a confusing state.
See CRITIQUE concern 2.

---

## 8. Salt-mined hub address with leading `f` bytes

**Choice.** The hub token is deployed at a vanity address with several
leading `f` bytes (e.g. `0xffff...`).

**Why.** V4 requires `currency0 < currency1` in every PoolKey. For the
single-sided-at-lower-bound spoke math to work, spokes must become
`currency0`, which means every spoke address must sort strictly below the
hub address. A hub starting with `f...` means almost every possible spoke
address sorts below it without needing to mine the spoke address.

This also stabilizes the single-sided fund formula. If spoke/hub sides
swapped case-by-case, `fund` would need branching logic to figure out
which side to fund and which tick boundary to seed at. With enforced
ordering there is exactly one currency0-sided formula and one
currency1-sided formula, selected by the `currency0Sided` flag in the
unlock payload.

**Cost.** The hub can't be an arbitrary existing ERC-20 — it has to be
deployed (or chosen) to satisfy the address constraint. In practice the
hub is minted specifically for Unispring, so this is a one-time deploy
cost, not an ongoing constraint.

---

## 9. `fund` is permissionless and re-callable

**Choice.** Any address can call `fund(token, supply, tickLower, tickUpper)`
any number of times on the same clone, with any token, paying its own
supply. No access control, no rate limit, no first-caller privilege.

**Why.** Permissionless funding is how "permanent liquidity" stays useful
over time. Because positions can never be removed, the only way a pool
grows is by being added to. Gating that behind a whitelist would move the
trust problem into an operator role; leaving it open lets communities,
treasuries, or the original funder add supply at any future price point.
See README §Patterns for the concrete use cases (staged emissions, ladder
launches, permanent supply removal, community-strengthened liquidity,
re-arming a sold-out position).

`transferFrom` pulls from `msg.sender`, so a re-caller funds with *their*
tokens — not the contract's balance. There is no self-allowance leak from
`zzInit`: the initial self-approval is fully consumed by the seed
transfer.

Re-funding is constrained by v4's single-sided math: the new range must
sit entirely on the side being funded. For the hub (currency1-sided),
`tickUpper` must be at or below the current pool tick. For a spoke
(currency0-sided), `tickLower` must be at or above the current tick.
In-range or wrong-side re-funds revert at `settle` because only one
currency is transferred but `modifyLiquidity` demands both. These
constraints are a feature — they prevent re-funds from bleeding value out
of existing positions.

**Cost.** A griefer can permanently lock tokens at ill-placed ticks, but
only with *their own* tokens. The cost is borne by the griefer.

---

## 10. Spoke isolation against malicious tokens

**Choice.** `fund` accepts any ERC-20 as the spoke token. A misbehaving
spoke (fee-on-transfer, rebasing, blacklisting, revert-on-transfer,
ERC777-style transfer hooks) can break its own pool but cannot compromise
the hub or any other spoke.

**Why the isolation holds.**

1. **Per-pool operations run only one token's code.** A `fund` call
   touches exactly one spoke; there is no cross-pool iteration and no
   shared balance across spokes.
2. **V4's single-locker model blocks transfer-hook reentrancy.** Each
   `POOL_MANAGER.unlock` installs the clone as the sole locker for the
   duration of `unlockCallback`. A malicious token's transfer hook cannot
   re-enter `fund` / `zzInit` (both call `unlock`, which reverts on
   nested entry) and cannot call the PoolManager directly because
   `modifyLiquidity` / `take` require `msg.sender == locker`.
3. **Atomic unwind on bad transfers.** Fee-on-transfer,
   revert-on-transfer, or under-delivery causes `settle` to underpay or
   revert, which unwinds the entire `fund` atomically. No partial state
   survives a broken token.

**Residual consequence.** A malicious spoke's own pool may end up with
less than nominal supply (whatever actually transferred). That is damage
to the bad spoke's own users, not to Unispring's invariants or any other
pool.

---

## 11. `zzInit` uses `this.fund` for the self-seed

**Choice.** `zzInit` does `hub_.approve(address(this), supply)` and then
`this.fund(hub_, supply, tickLower, tickUpper)` — invoking `fund` as an
external call on its own address rather than an internal helper.

**Why.** `fund` does `token.transferFrom(msg.sender, address(this), supply)`
as its first step. With an internal call, `msg.sender` would be PROTO (the
original `zzInit` caller), which holds no hub balance. The external
self-call rewrites `msg.sender` to `address(this)` — the clone itself —
and the self-approval set on the line above lets `transferFrom` succeed
against the clone's own hub balance. The msg.sender rewrite is the
load-bearing reason; keeping a single funding code path is secondary.

---

## 12. Unlock callback has a single code path

**Choice.** `unlockCallback` decodes the payload as a plain tuple and
funds the position inline. There is no action enum, no tagged union — one
operation only.

**Why.** Unispring has exactly one operation that needs the unlock
context: funding a single-sided position. Both entry points (`fund` and
the `zzInit` → `this.fund` re-entry) reach the callback with the same
payload shape. A `currency0Sided` boolean selects hub-side vs spoke-side
math without changing the control flow.

---

## 13. Permanence: no unwind path

**Choice.** There is no function to remove liquidity, collect principal,
or unwind a position. `unlockCallback` only handles the add-liquidity
direction.

**Why.** Permanence is the whole point. The lack of a withdraw path is
why positions are locked forever, why integrators can treat Unispring
pools as terminal rather than revocable, and why no "admin can rug"
attack exists. `FEE = 0` means there is also no fee-collection path — no
reason to call the PoolManager after the initial fund except to add more
liquidity via another `fund`.

**Cost.** A mistake at fund time (wrong range, wrong supply) is
permanent. Mitigation: the `(hub, tickLower, tickUpper)` clone key means
a misconfigured deploy lives at a different address than the intended
one, so a second `make` with the right parameters yields a distinct
clone that doesn't collide.

---

## 14. Post-buyout dynamics

**Scenario.** A single-sided spoke position is fully crossed by buyers.
Price sits at `tickUpper`, the position holds 100% hub, and the pool
contributes no liquidity above spot. What third parties can and can't
do at that point — a catalog of the emergent market around a spent
Unispring position. Complements the "Re-arming a sold-out position"
bullet in README §Patterns.

**Above `tickUpper` via `fund`.** The canonical path. A follow-on `fund`
call with `tickLower ≥ currentTick` adds a new permanent single-sided
spoke position at higher prices. Permissionless and re-callable (§9),
so anyone — original funder, treasury, random holder — can extend the
sell curve.

**Above `tickUpper` via direct V4 LP in the same pool.** A third party
can call `POOL_MANAGER.modifyLiquidity` against the Unispring PoolKey
without going through Unispring. That position aggregates additively
with anything Unispring deposited — same pool, same fee, same tick
grid, no "competition" between positions. The meaningful distinction
against `fund` is *ownership*: a direct V4 position is owned by
`msg.sender` and is withdrawable; a `fund` position is owned by the
clone with no exit path. Both earn zero (fee = 0), so the economic
rationale for direct LP is staged distribution *with an out*, not
yield.

**Above `tickUpper` via a parallel pool at non-zero fee.** A distinct
PoolKey `(currency0, currency1, fee > 0, ...)` is a distinct venue.
Aggregators enumerate standard fee tiers and route across both. In any
tick range where the zero-fee pool has depth, cost-minimizing routing
prefers it; a fee-bearing pool overlapping Unispring's live range loses
the flow. *Above* the spent `tickUpper` the zero-fee pool has no
depth, so a fee-bearing pool has that range to itself until someone
re-funds the zero-fee side. That window is the one regime where a
parallel pool has economic room.

**Below `tickLower`.** Dead capital. The floor is enforced by absence
of liquidity (§6), and V4's swap math cannot cross an empty tick
range, so no canonical path drives spot below `tickLower`. A position
placed below it only ever activates if some external mechanism first
drags spot below the floor — which no standard V4 route exposes.

**"Bought out" is not terminal.** The fully-crossed position sits as
100% hub at `tickUpper`. That hub is itself a permanent bid: the first
seller back across the boundary consumes it and reactivates the
original position. A spoke pool therefore alternates between "active at
spot inside `[tickLower, tickUpper]`" and "saturated at `tickUpper`
awaiting the next sell." The saturated state is a waiting state, not a
dead state — which is why re-funds and parallel pools above `tickUpper`
are optional enhancements, not required repairs.

---

## Non-goals

Things Unispring deliberately does **not** try to do:

- **Multiple fee tiers.** Zero-fee only. See §5.
- **Custom hooks.** The `hooks` field in every Unispring PoolKey is
  `address(0)`. Hooks would fragment the liquidity graph and re-open the
  "which pool is canonical for this pair" question.
- **Governance.** No owner, no admin, no upgrade, no timelock.
- **Fee skimming / LP rewards.** No fees exist to skim.
- **Withdraw / unwind path.** See §13.
- **Token minting.** Hub and spokes are deployed externally (see the
  Lepton launcher). Unispring takes existing tokens and locks them as
  LP.

Unispring is a single opinionated recipe. Projects that want something
different use V4 directly.
