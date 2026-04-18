# Unispring — outsider critique

A running list of concerns to address and benefits to preserve, from an
outsider's reading of [src/Unispring.sol](src/Unispring.sol). Each item is
numbered so we can refer to them in commits and PRs.

## Benefits (preserve these)

1. **Pre-committed fair launch.** Single-sided full-range seed with no LP
   tokens minted to anyone — the liquidity is locked by virtue of nobody
   owning it. The deployer cannot rug post-seed.

2. **Hard price floor baked into pool geometry.** Seed priced at `tickFloor`
   with range `[floor, MAX]` (or the mirror for the hub) means the token
   literally cannot trade below floor. Property of the tick range, not a
   hook — survives any future governance.

3. **Hub-and-spoke routing discipline.** Every spoke is HUB-paired at the
   0.01% tier, so a single liquidity graph emerges and SOR's fallback
   enumeration finds everything. No fragmentation by default.

4. **Permissionless fee compounding (`plow`).** No operator, no reward, no
   trust — anyone pays the gas to fold fees back in. Position grows
   monotonically.

5. **Deterministic currency0 ordering via salt-mined hub address.** The
   leading-`f` hub address means any reasonable spoke address sorts below
   it, so spokes are always `currency0` and the single-sided math always
   works out to "zero hub capital required."

## Concerns (address these)

1. **Unispring membership is a weak trust signal on its own.** `fund` is
   permissionless, so "this token is in Unispring" only tells you its
   supply is floor-locked — it says nothing about the token's bytecode
   (could be fee-on-transfer, rebasing, blacklisting, upgradeable, or
   hold a hidden mint).

   **Proposed fix:** a launcher contract that, in a single transaction,
   (a) calls [Lepton](../lepton/src/Lepton.sol) to mint a fresh fixed-supply
   clone, and (b) seeds the entire supply into Unispring via `fund`.
   Tokens that emerge from this launcher carry a strong composite guarantee:
   vanilla Lepton bytecode (no mint, no blacklist, no fee-on-transfer, no
   upgrade) + entire supply locked behind a Unispring floor + nobody holds
   any of it post-seed. Front-ends and indexers can trust the launcher
   address as a whitelist rather than trusting Unispring membership.

   Unispring itself stays permissionless — the trust layer lives one level
   up, in the launcher.

2. **Hub bootstrap is a two-step dance.** `seedHub` leaves the pool inactive
   at spot until someone does an ETH → HUB swap through any Uniswap router;
   between those two txs the pool exists but quoters see it as dead. A
   deploy pipeline can fire the bootstrap swap back-to-back with seeding,
   but any external caller racing in sees a confusing state. Consider
   fusing the two, or documenting the race.

3. **0.01% fee tier — deliberate, not accidental.** The tier optimizes
   for discoverability and routing (it is one of the canonical tiers
   every SOR enumerates, and it keeps routed `ETH→HUB→spoke` trades
   competitive at 0.02% round-trip) at the cost of slow moat growth
   via `plow`. Unispring's opinionated stance is: *one recipe, one
   tier*. Projects that want a different fee/tickSpacing can bypass
   Unispring and call the PoolManager directly — V4 is the substrate,
   Unispring is one recipe on top of it. The rationale is worth a
   comment on `FEE` so future readers don't mistake it for an oversight.

4. **Malicious spoke tokens — blast radius is self-contained.** A bad
   spoke (fee-on-transfer, rebasing, blacklisting, revert-on-transfer,
   ERC777-style transfer hooks) can break its own pool but cannot
   compromise the hub or any other spoke. Worth documenting *why* in the
   contract, because a reader shouldn't have to reconstruct the argument.

   **Isolation properties that hold:**

   - Per-pool operations never run another spoke's code. `fund` and
     `_plow` only touch the token for the pool they operate on.
   - v4's `PoolManager` enforces a single active locker via transient
     storage. A malicious token's transfer hook cannot re-enter
     `plow` / `fund` / `seedHub` (each calls `unlock`, which reverts
     on nested entry), and it cannot call the PoolManager directly
     because `take` / `swap` / `modifyLiquidity` require
     `msg.sender == locker`.
   - Unispring's HUB balance (carryover from prior plows across all
     pools) is safe: during a plow, `HUB.transfer` is only called for
     the exact `owed` amount the PoolManager computes for the current
     add. A foreign spoke's transfer hook has no path to move HUB.
   - Fee-on-transfer, rebasing, or revert-on-transfer cause `settle` to
     underpay or revert, unwinding the entire plow atomically. No partial
     state, no leaks.

   **Residual consequence:** a bad spoke becomes un-plowable, permanently.
   Its fees accrue in the pool but can't be compounded back. Cosmetic,
   not a compromise.

   **Proposed fixes (pick any):**
   - Add a NatSpec block on `fund` spelling out the isolation
     argument, so future readers don't have to re-derive it.
   - Prefer pairing Unispring with the Lepton launcher (concern 1) so
     the supported-token-shape question never arises in practice.

