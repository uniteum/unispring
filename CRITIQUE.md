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

3. **Hub-and-spoke routing discipline.** Every spoke is hub-paired at the
   zero-fee tier, so a single liquidity graph emerges and SOR's fallback
   enumeration finds everything. No fragmentation by default, and routed
   `ETH → hub → spoke` trades pay zero fees at both hops.

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

   **Proposed fix:** a launcher contract that, in a single transaction,
   (a) calls [Lepton](../lepton/src/Lepton.sol) to mint a fresh
   fixed-supply clone, and (b) seeds the entire supply into Unispring via
   `fund`. Tokens that emerge from this launcher carry a strong composite
   guarantee: vanilla Lepton bytecode (no mint, no blacklist, no
   fee-on-transfer, no upgrade) + entire supply locked behind a Unispring
   floor + nobody holds any of it post-seed. Front-ends and indexers can
   trust the launcher address as a whitelist rather than trusting
   Unispring membership.

   Unispring itself stays permissionless — the trust layer lives one
   level up, in the launcher.

2. **Hub bootstrap is a two-step dance.** `make` triggers `zzInit`, which
   leaves the hub/ETH pool inactive at spot until someone does an
   ETH → hub swap through any Uniswap router; between those two txs the
   pool exists but quoters see it as dead. A deploy pipeline can fire the
   bootstrap swap back-to-back with `make`, but any external caller
   racing in sees a confusing state. Consider fusing the two, or making
   the race more visible to integrators beyond DESIGN.md §7.

3. **No native moat growth.** `FEE = 0` means pools never accumulate
   fees, so a pool's depth is whatever was funded plus whatever future
   `fund` calls add. A neglected spoke — no community, no follow-on
   funding — stays at its launch depth forever. That's by design
   (DESIGN.md §5), but it places the entire burden of depth-building on
   social coordination rather than mechanics. Worth flagging because it
   changes the success criteria for a launch: "seeded and abandoned" is
   a much weaker outcome here than in a fee-accruing pool.
