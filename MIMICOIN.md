# Mimicoin

A **Mimicoin** is an ERC-20 token that trades 1:1 with an **original**
token within a 1-bp band, backed by a single permanent Uniswap V4 position.
For any original — USDC, WBTC, USDe — you get a mirror: `USDCx1`, `WBTCx1`,
`USDex1`, pegged within `[0.9999, 1.0001]` with no oracle and no power to
unwind.

The factory that creates them is **Mimicoinage** — a singleton with one
launch function. Each call mints a fresh Mimicoin and seats its entire
supply into a single-tick V4 pool at price 1. The position is owned by
the Mimicoinage contract itself and cannot be decreased, withdrawn, or
destroyed: the contract exposes no function for reducing liquidity. Only
accrued swap fees (at 0.01%) can be collected — permissionless to trigger,
always forwarded to the factory owner.

## How the peg works

The pool is a single-tick concentrated liquidity position at tick 0, with
tick-spacing 1 (one bp wide). Because the starting price sits exactly at
the edge of the range, the position begins 100% Mimicoin and 0% original.
A buyer brings the original, receives Mimicoin, and walks price into the
band. A seller reverses. The AMM does the rest.

Both sides of the pool are real tokens, so the floor and ceiling are hard:
nobody pays more than `1.0001 × original` for a Mimicoin, nobody sells for
less than `0.9999 × original`. With 10²⁷ raw mimic units seeded, the pool
cannot be drained by any quantity of original that exists.

Because the position is permanent and no party can decrease it, the
backing is as durable as the pool itself. The owner's only stream of
value from a launched Mimicoin is the ongoing 0.01% fee on swap volume.

## What it's for

- **Permissionless stablecoin mirror.** Deploy `USDCx1` alongside USDC
  with its own address, integrations, and reputation — collateralized
  1:1 by real USDC in the pool, with no unwind path for anyone.
- **Free-floating distribution.** Airdrop or distribute Mimicoin knowing
  every unit is redeemable 1:1 against the original, forever.
- **Cross-venue scaffold.** Mirror a native asset on a venue where
  bridging the real thing isn't feasible.
- **Dev-chain tracking.** Sandbox tokens that track real-world prices
  without oracle plumbing.

## What it isn't

- **Not elastic.** Supply is fixed at launch; no mint-on-demand, no
  burn-on-redeem. The peg is held by the pool's inventory, not by
  issuance.
- **Not an oracle.** If the original depegs from its own reference
  asset, the Mimicoin tracks the original, not the reference.
- **Not a yield source for the owner beyond fees.** The owner cannot
  harvest the accumulated original by unwinding — only the 0.01% fee
  stream is extractable.

## TL;DR

A Mimicoin is a real ERC-20 with a hard 1-bp price corridor around any
original token, collateralized by real originals in a permanent V4
position that no one — including the factory owner — can unwind.
