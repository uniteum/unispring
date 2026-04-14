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

1. **Unispring membership is a weak trust signal on its own.** `addSpoke` is
   permissionless, so "this token is in Unispring" only tells you its
   supply is floor-locked — it says nothing about the token's bytecode
   (could be fee-on-transfer, rebasing, blacklisting, upgradeable, or
   hold a hidden mint).

   **Proposed fix:** a launcher contract that, in a single transaction,
   (a) calls [Lepton](../lepton/src/Lepton.sol) to mint a fresh fixed-supply
   clone, and (b) seeds the entire supply into Unispring via `addSpoke`.
   Tokens that emerge from this launcher carry a strong composite guarantee:
   vanilla Lepton bytecode (no mint, no blacklist, no fee-on-transfer, no
   upgrade) + entire supply locked behind a Unispring floor + nobody holds
   any of it post-seed. Front-ends and indexers can trust the launcher
   address as a whitelist rather than trusting Unispring membership.

   Unispring itself stays permissionless — the trust layer lives one level
   up, in the launcher.

2. **`tx.origin` in the `Plowed` event.** See [src/Unispring.sol:471](src/Unispring.sol#L471)
   and [src/Unispring.sol:491](src/Unispring.sol#L491). Not a security
   issue (event topic only) but surprising — use `msg.sender`.

3. **Hub bootstrap is a two-step dance.** `seedHub` leaves the pool inactive
   at spot until someone calls `buyHub`; between those two txs the pool
   exists but quoters see it as dead. A deploy script handles this, but any
   external caller racing in sees a confusing state. Consider fusing the
   two, or documenting the race.

4. **0.01% fee tier is the worst tier for fee plowback economics.** Chosen
   for router discoverability, but a token that expects its moat to be
   compounded fees will compound very slowly. Either justify in code
   comments or reconsider.

5. **No escape hatch for malicious spoke tokens.** `addSpoke` does an
   unchecked `transferFrom` (lint suppressed at [src/Unispring.sol:295](src/Unispring.sol#L295)).
   A fee-on-transfer, rebasing, or blacklisting token could poison `plow`
   forever for that pool. Document the supported token shapes or add a
   probe.

6. **`floor` namespace invariant is undocumented.** `floor[HUB]` and
   `floor[token]` share a single `address => int24` mapping. The
   `SpokeMustSortBelowHub` check prevents collision with `HUB`, but the
   invariant isn't stated anywhere. Add a NatSpec line.

7. **`UnknownToken` detection uses `floor[token] == 0`.** See
   [src/Unispring.sol:340-341](src/Unispring.sol#L340-L341). A legitimate
   `tickFloor` of exactly 0 would be indistinguishable from "unknown." The
   constructor forbids `<= MIN_TICK` and `>= MAX_TICK` but allows 0. Either
   forbid 0 explicitly or switch to a separate `registered` mapping.
