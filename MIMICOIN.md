# Mimicoin

A **Mimicoin** is an ERC-20 token that trades 1:1 with a reference ("quote")
token within a 1-bp band, backed by a single Uniswap V4 position. For any
quote — USDC, WBTC, USDe — you get a mirror: `USDCx1`, `WBTCx1`, `USDex1`,
pegged within `[1.0000, 1.0001)` with no operator, no oracle, and no admin
keys.

The factory that creates them is **Mimicoinage** — a singleton with one
function: `launch(quoteToken, name)`. Each call mints a fresh Mimicoin and
seats its entire supply into a single-tick V4 pool at price 1. The liquidity
NFT goes to the factory owner; everything else is permissionless.

## How the peg works

The pool is a single-tick concentrated liquidity position at tick 0, with
tick-spacing 1 (one bp wide). Because the starting price sits exactly at
the edge of the range, the position begins 100% Mimicoin and 0% quote. A
buyer brings quote, receives Mimicoin, and walks price into the band. A
seller reverses. The AMM does the rest.

Both sides of the pool are real tokens, so the floor and ceiling are hard:
nobody pays more than `1.0001 × quote` for a Mimicoin, nobody sells for
less than `0.9999 × quote`. With 10²⁷ raw mimic units seeded, the pool
cannot be drained by any quantity of quote that exists.

## What it's for

- **Permissionless stablecoin mirror.** Deploy `USDCx1` alongside USDC with
  its own address, integrations, and reputation — collateralized 1:1 by
  real USDC in the pool.
- **Fixed-price token sale.** Launch a token at exactly $1 with no ICO
  machinery. Buyers bring USDC; the pool hands out tokens; the owner holds
  the NFT and claims the accumulated USDC later by unwinding the position.
- **Fixed-price distribution.** Airdrop or distribute claims knowing every
  unit is redeemable 1:1 against the quote.
- **Cross-venue scaffold.** Mirror a native asset on a venue where
  bridging the real thing isn't feasible.
- **Dev-chain tracking.** Sandbox tokens that track real-world prices
  without oracle plumbing.

## What it isn't

- **Not elastic.** Supply is fixed at launch; no mint-on-demand, no
  burn-on-redeem. The peg is held by the pool's inventory, not by
  issuance.
- **Not an oracle.** If the quote token depegs from its own reference
  asset, the Mimicoin tracks the quote token, not the reference.

## TL;DR

A Mimicoin is a real ERC-20 with a hard 1-bp price corridor around any
quote token, collateralized by real quote already in the pool, deployable
in one transaction.
