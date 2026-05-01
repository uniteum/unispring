# Mimicoin

A **Mimicoin** is an ERC-20 token whose price tracks a chosen
**original** token (USDC, WBTC, USDe, …) inside a one-basis-point
band: never below `1.0 × original`, never above `1.0001 × original`.
The peg is held by a single permanent Uniswap V4 position holding the
real original. No oracle, no operator, no path to unwind the backing.

The factory that mints them is **Mimicry**.

## How Mimicry is laid out

Mimicry is a two-level factory built on the prototype-and-clones
pattern: one **prototype** contract is deployed once per chain, and
each call to its `make` function creates a cheap [EIP-1167] minimal
proxy clone at a deterministic [CREATE2] address. The prototype holds
all the logic; clones hold only their own configuration.

[EIP-1167]: https://eips.ethereum.org/EIPS/eip-1167
[CREATE2]: https://eips.ethereum.org/EIPS/eip-1014

Mimicry stacks two of these levels:

1. **Clones, one per `(original, symbol)` pair.**
   `mimicry.make(USDC, "USDCx1")` deploys (or returns) the clone that
   acts as the `USDCx1` factory. Every Mimicoin minted by this clone
   carries the symbol `USDCx1` and is pegged against USDC.
2. **Mimicoins, one per `name` within a clone.**
   `clone.mimic("alpha")` mints a fresh ERC-20 — itself a
   deterministically-addressed CREATE2 deploy via the
   [Coinage](https://github.com/uniteum/lepton) ERC-20 factory — and
   seats its entire supply into a Uniswap V4 pool against the
   original. Calling `mimic` again with the same name is a no-op that
   returns the existing token.

Native ETH is a special case. Because deploying a clone for the canonical
ETH pair would be wasted gas, the **prototype itself** is the factory
for `(native ETH, "1xETH")`. So `mimicry.mimic("alpha")` — called
directly on the prototype, with no `make` first — mints a 1xETH
Mimicoin pegged against ETH.

Each `mimic(name)` call is a one-shot:

1. Mints a fixed-supply ERC-20 carrying the original's decimals.
2. Initializes a Uniswap V4 pool pairing the new token against the
   original (or native ETH).
3. Deposits 100% of the supply into a single concentrated-liquidity
   position spanning a single tick (the smallest unit Uniswap permits)
   at price 1, anchored to the floor.
4. Locks the position permanently in a **Fountain** — the
   liquidity backend Mimicry delegates to. Neither Mimicry nor
   Fountain has any way to decrease, withdraw, or destroy the
   position. Only accrued swap fees can be collected.

## How the peg works

A V4 pool's price moves along a discrete grid of **ticks**. Each tick
is one basis point (one part in ten thousand) of price: moving up one
tick multiplies the price by `1.0001`. Tick 0 corresponds to a price
of exactly 1.

A V4 position has a tick range; outside that range the position
contributes no liquidity, and a swap that would push the price off
the end of the range simply has nothing to fill against. This is what
**concentrated liquidity** means in V4: every position is bounded.

Mimicry seats every Mimicoin's entire supply into one position
spanning the tick range `[0, 1)` — exactly one tick wide, one bp.
Because the pool is initialized at the lower edge (tick 0), the
position starts holding 100% Mimicoin and 0% original.

What that geometry means in practice:

- **A buyer** brings the original and receives Mimicoin, walking the
  price up through the band toward tick 1. The most they ever pay is
  `1.0001 × original` per Mimicoin — the upper edge of the range.
- **A seller** brings Mimicoin and pushes the price back down. But
  the position only exists between tick 0 and tick 1, so price
  *cannot fall below tick 0*: there is no liquidity beneath the floor
  for the sale to fill against. The lowest a seller ever receives is
  `1.0 × original` per Mimicoin.

Both walls are real tokens (real Mimicoin on the way up, real
original on the way down), so neither side runs out unexpectedly.
The lower wall isn't a soft target enforced by an oracle or a hook —
it's a hard wall arising from V4's swap math, which can't cross an
empty tick range.

The supply seeded into each position is sized to the original's
decimals — `10²⁷` raw units when the original has 18 decimals or
more, scaled down by a factor of 10 per decimal below 18 — so every
Mimicoin has roughly the same human-unit supply (about a billion
tokens) regardless of its original. For any plausible original this
means the pool cannot be drained by a real-world quantity of buyers.

Because the position is permanent and cannot be reduced, the backing
is as durable as the pool itself. The only stream of value that flows
back out of a launched Mimicoin is the 0.01% fee on swap volume,
which Fountain forwards to its **owner** (the address that deployed
the Fountain). That address has no other authority — it cannot reach
the principal or modify the pool.

## What it's for

- **Permissionless stablecoin mirror.** Deploy `USDCx1` alongside USDC
  — its own address, integrations, and reputation — collateralized
  1:1 by real USDC in the pool, with no unwind path for anyone.
- **Free-floating distribution.** Airdrop or distribute Mimicoin
  knowing every unit is redeemable for at least 1× the original,
  forever.
- **Cross-venue scaffold.** Mirror a native asset on a venue where
  bridging the real thing isn't feasible.
- **Dev-chain tracking.** Sandbox tokens that track a real-world
  price without oracle plumbing.

## What it isn't

- **Not elastic.** Supply is fixed at launch — no mint-on-demand, no
  burn-on-redeem. The peg is held by the position's inventory, not
  by issuance.
- **Not an oracle.** If the original depegs from its own reference
  asset, the Mimicoin tracks the original, not the reference.
- **Not a yield source beyond fees.** The Fountain owner cannot
  harvest accumulated original by unwinding the position — only the
  0.01% fee stream is extractable.

## TL;DR

A Mimicoin is a real ERC-20 with a hard one-basis-point price
corridor: its price never drops below `1.0 ×` the original and never
rises above `1.0001 ×`. The backing is real originals locked in a
permanent V4 position that no one — including the Fountain owner —
can unwind.
