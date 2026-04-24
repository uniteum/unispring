# Unispring — outsider critique

A running list of concerns to address and benefits to preserve, from an
outsider's reading of [src/Unispring.sol](src/Unispring.sol). Each item is
numbered so we can refer to them in commits and PRs.

## Benefits (preserve these)

1. **Pre-committed fair launch.** Single-sided seed with no LP tokens minted
   to anyone — the liquidity is locked by virtue of nobody owning it, and
   there is no withdraw path anywhere in the contract. The funder cannot
   rug post-seed.

2. **Hard price floor baked into pool geometry.** Spoke pools initialize at
   `tickLower` with a single-sided position on `[tickLower, tickUpper]`, so
   the token literally cannot trade below `tickLower`. Property of the tick
   range, not a hook — no governance surface to attack.

3. **Hub-and-spoke routing discipline.** Every spoke is hub-paired at
   the 0.01% tier, so a single liquidity graph emerges and SOR's
   fallback enumeration finds everything. No fragmentation by default,
   and routed `ETH → hub → spoke` trades pay the same 0.01% at both
   hops (0.02% total across the two-hop).

4. **Permissionless, re-callable `fund`.** No operator, no reward, no
   trust — anyone can lock more permanent liquidity on any pool at any
   time. Positions grow monotonically because there is no unwind path, so
   every `fund` call strictly adds to the locked supply. Patterns that
   fall out (staged emissions, ladder launches, community top-ups) don't
   require any governance or admin role.

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

   **Status: implemented as `NeutrinoSource`.** `NeutrinoSource.launch`
   calls Coinage (deploying a vanilla Lepton ERC-20: no mint, no
   blacklist, no fee-on-transfer, no upgrade) and immediately funds the
   entire supply into this clone's Unispring. Tokens that emerge from
   a NeutrinoSource launch carry the composite guarantee: vanilla
   Lepton bytecode + entire supply locked behind a Unispring floor +
   nobody holds any of it post-seed. Front-ends and indexers can trust
   the NeutrinoSource address as a whitelist rather than trusting raw
   Unispring membership.

   Unispring itself stays permissionless — the trust layer lives one
   level up, in NeutrinoSource.

2. **Hub bootstrap is a two-step dance.** `make` triggers `zzInit`, which
   leaves the hub/ETH pool inactive at spot until someone does an
   ETH → hub swap through any Uniswap router; between those two txs the
   pool exists but quoters see it as dead. A deploy pipeline can fire the
   bootstrap swap back-to-back with `make`, but any external caller
   racing in sees a confusing state. Consider fusing the two, or making
   the race more visible to integrators beyond DESIGN.md §7.

3. **Fees flow to a `taker`, not to the pool.** `FEE = 100` generates
   revenue, but the accrued fees stream to Fountain's `taker` address
   via `Fountain.take` instead of compounding back into the position
   (positions are permanent and Fountain exposes no increase path tied
   to fee growth). A pool's *principal depth* is therefore whatever was
   funded plus whatever future `fund` calls add — fees don't thicken
   it. That's by design (DESIGN.md §5 and §13), but it's worth
   flagging: a neglected spoke with no community and no follow-on
   funding stays at its launch depth forever, and the fee stream
   enriches the taker rather than the holders. The success criteria
   for a Unispring launch include both "who keeps re-funding?" and
   "what does the taker do with accrued fees?"
