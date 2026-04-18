# Unispring

Fair-launch token factory on Uniswap V4 — permanent liquidity, built-in
price floor, zero maker capital, zero fees.

## Overview

Unispring creates tokens that are immediately tradeable on Uniswap V4
with fair-launch economics and a permanent price floor.

In a single transaction, the protocol:

1. Mints a fixed-supply ERC-20 token via [Lepton](https://github.com/uniteum/lepton)
2. Initializes a Uniswap V4 pool against the hub token
3. Deposits 100% of the supply as a single-sided concentrated position
4. Locks the position permanently in the singleton factory

No allocation. No presale. No operator. **No capital from the maker.**
The only way to acquire tokens is buying them from the pool.

## Why Unispring

### The problem with custom AMMs

Protocols like [Solid](https://uniteum.one/solid/) provide fair-launch
tokens with built-in liquidity and a permanent price floor. But the
liquidity lives in a custom AMM — isolated from the rest of DeFi.

Bridging that liquidity to Uniswap requires an external arbitrage
keeper ([UniSolid](https://github.com/uniteum/unisolid)), a Chainlink
Automation subscription, and ongoing gas costs. The result is four
moving parts where one should suffice.

### The Unispring approach

Unispring achieves the same economic properties — fair launch, price
floor, always tradeable — by deploying directly into Uniswap V4.

No custom AMM. No keeper. No arbitrage latency.

Tokens are immediately tradeable on any Uniswap frontend, DEX
aggregator, or smart contract that routes through Uniswap V4.

## The hub model

Every Unispring token is paired against a single common token: the
**hub**. Because all Unispring tokens share the same hub, any two of
them are reachable in two hops — sell A for hub, buy B with hub —
giving the entire family of Unispring tokens native routability through
Uniswap's standard aggregator paths.

The hub is a constructor parameter on the factory. The canonical
deployment uses [Uniteum 1](https://uniteum.one/uniteum-1/) as its hub.

## Design

### Fair launch with zero maker capital

The entire token supply starts in the Uniswap V4 pool as a single-sided
position. The maker provides **no hub tokens** — only gas. There is no
founder bag because there is no founder deposit.

The maker participates by buying from the pool like everyone else.

### Price floor

The seeded position spans `[tickFloor, MAX_TICK]`, and the pool's
initial price is set exactly at `tickFloor`. Two consequences follow:

- The position is single-sided in the new token, requiring zero hub
  tokens to seed.
- Below `tickFloor` there is no liquidity at all. Sells cannot push the
  price past it because there is nothing on the other side to fill
  against. The floor is enforced by the **absence** of liquidity, not
  by a hook or custom curve.

`tickFloor` is chosen by the maker at `make()` time and is permanent.

### Price dynamics

As tokens are bought out of the pool, price rises along the
concentrated-liquidity curve and hub tokens accumulate in the position.
Selling returns tokens to the pool and lowers the price — but never
below the floor. There is no upper bound; the position extends to
`MAX_TICK`.

### Zero fee

Pools are created with `fee = 0`. There is no swap fee, so there are no
fees to compound, no caller-reward function, and no operator role of any
kind. The factory exists only to mint, seed, and lock — once `make()`
returns, the pool needs nothing further.

This is a deliberate trade-off: cheaper trading and a smaller contract
surface, at the cost of any fee-driven liquidity deepening over time.
The depth of the position is fixed at the supply that was minted.

### Singleton factory

Unispring is a single contract on chain. It is the maker, owner, and
custodian of every position it creates. Positions are keyed by
Uniswap V4 `PoolId`, so all per-token state lives in mappings rather
than per-token clones.

The factory has:

- No owner
- No upgrade path
- No way to withdraw any position
- No governance parameters

Once a token is made, its rules are fixed.

### Immutability

Uniswap V4's `PoolManager` is immutable — no admin keys, no upgrade
proxy. Lepton is immutable. Unispring is immutable. A token deployed
through this stack inherits immutability from end to end.

### Trust boundaries

Unispring, NeutrinoSource, and NeutrinoChannel are **factories**. Their
job is to mint a token, initialize a pool, and lock a single-sided
position. Once that work is done, none of them has any authority over
what they created — they cannot pause a token, reclaim a position,
change a fee, or route a trade. The ongoing behavior of a launched
token is split between two contracts that the factories do not control:

| After launch, ...                  | ... is governed by                                                |
|:-----------------------------------|:------------------------------------------------------------------|
| Token transfers, approvals, supply | Lepton (the ERC-20 implementation)                                |
| Swap math, pool state, liquidity   | The Uniswap V4 PoolManager — plus any DEX router that reaches it  |

Concretely:

- **NeutrinoChannel** relays one `Coinage.make()` call per clone and
  transfers the minted supply to its caller. After `mint()` returns,
  it holds no tokens and has no privileged relationship with the one
  it just minted.
- **NeutrinoSource** composes a channel-minted hub with a Unispring
  clone at `make()`, then on each `launch()` mints a spoke and hands
  it to Unispring for funding. The clone retains no claim on either
  token or on the pool.
- **Unispring** funds a permanent single-sided position via
  `PoolManager.modifyLiquidity`. The position has no owner in any
  meaningful sense — Unispring holds the nominal position key but
  exposes no method to withdraw, collect, or modify it.

So the security surface a maker or holder needs to reason about is
narrow: **Lepton** (does the ERC-20 behave correctly?) and **Uniswap
V4** (does the pool honor its stated math?). The factories above them
are one-shot and step aside.

## How it works

```
make(name, symbol, supply, tickFloor, salt)
        │
        ▼
┌──────────────────────────────┐
│  Lepton mints fixed supply    │
│  at a CREATE2 address that    │
│  sorts strictly below the hub │
│  Initialize V4 pool at floor  │
│  Deposit 100% as single-sided │
│  position [floor, MAX_TICK]   │
│  Position locked in factory   │
└──────────────────────────────┘
        │
        ▼
  Token is live on Uniswap V4 —
  tradeable on any frontend or
  aggregator immediately
```

### Token ordering and the floor

Unispring seeds every pool with a single-sided position that holds
**only the new token** and requires **zero hub capital**. That
constraint plus Uniswap V4's tick conventions forces a rule that looks
arbitrary at first glance but is actually load-bearing:

> **The new token's address must sort strictly below the hub's address.**

The maker guarantees this by mining a Lepton salt off-chain until the
deterministic CREATE2 address satisfies the constraint. Unispring's
`make()` reverts if it doesn't. The rest of this section explains why
the rule has to exist.

#### The two Uniswap conventions that collide

Every Uniswap V4 position is a tick range `[tickLower, tickUpper]`.
Two separate pieces of code inspect the current tick against that
range, and they use **different boundary conventions**:

- **Active-liquidity check** (does this position contribute depth right
  now?) uses a half-open interval:
  `tickLower ≤ currentTick < tickUpper`. The lower bound is
  **inclusive**, the upper bound is **exclusive**.
- **Token-composition check** (what does this position hold at the
  current price?) uses a closed interval: at
  `sqrtPriceCurrent == sqrtPriceLower` the position is 100%
  `currency0`; at `sqrtPriceCurrent == sqrtPriceUpper` it is 100%
  `currency1`. **Both** endpoints are inclusive.

At the **lower** boundary the two conventions agree: `currentTick`
exactly equal to `tickLower` means active *and* single-sided in
`currency0`. At the **upper** boundary they disagree: `currentTick`
exactly equal to `tickUpper` means single-sided in `currency1` but
*not* active. This is the Uniswap equivalent of a fencepost error —
the two checks count endpoints differently, and only one corner of the
range ends up in the intersection.

#### What that means for Unispring

Unispring wants to deposit the entire supply of the new token into a
position that is (a) active at spot — so quoters and aggregators can
route through it immediately — and (b) holds only the new token — so
the maker doesn't need to supply any hub.

Those two requirements *can* both be satisfied, but only at the **lower
boundary** of a range, where the conventions align. So the position
must be shaped so that the new token sits on the side corresponding to
that lower-boundary seed: the new token must be `currency0`, the range
must be `[tickFloor, MAX_TICK]`, and the pool must be initialized at
exactly `sqrtPrice(tickFloor)`.

The mirror configuration — new token as `currency1`, seeded at the
upper boundary of `[MIN_TICK, -tickFloor]` — looks symmetric but
isn't. At `currentTick == tickUpper` the position is single-sided in
`currency1` (correct) but contributes zero active liquidity (wrong).
Swap math can eventually cross the boundary on the first trade and
activate the position, but quoters and frontends pre-filter on
`getLiquidity > 0` and will never simulate the crossing. The pool
would exist on chain and be invisible to every aggregator.

Nudging the initial tick one step inside the range doesn't rescue
the mirror case: the position becomes genuinely mixed and Uniswap
demands some `currency0` (hub) from the maker, violating the
zero-capital invariant. The fencepost is load-bearing — there is no
tick arithmetic trick that fixes it.

The only clean resolution is to avoid the mirror case entirely by
ensuring `newToken < hub`.

#### Enforcing the ordering via salt mining

Lepton accepts a caller-supplied `salt` for its CREATE2 deployment,
and exposes a pure `made()` view so addresses can be predicted
off-chain without spending gas. The maker runs a small loop:

```
for salt in 0, 1, 2, ...:
    addr = lepton.made(maker, name, symbol, supply, salt).home
    if addr < hub:
        break
```

and then calls `unispring.make(name, symbol, supply, tickFloor, salt)`
with the winning salt. Unispring recomputes the address via Lepton's
deterministic deployment and reverts with
`NewTokenMustSortBelowHub(newToken)` if the constraint isn't met.

The expected number of salts to try is
`addressSpace / (addressSpace - hubValue)` — i.e. the smaller the hub
address, the more tries. This is why the canonical hub is deployed at
an address with several leading `f` bytes: it makes the search
succeed on the first try for almost every `(name, symbol, supply)`
combination, so in practice callers submit `salt = 0` and never think
about it. The cost of mining a "big" hub address is paid **once**,
at hub deployment, and amortized across every Unispring token that
will ever be created.

#### Summary

The position is `[tickFloor, MAX_TICK]`. The pool's initial tick is
exactly `tickFloor`. The new token is `currency0`, the hub is
`currency1`. This is the only configuration that is simultaneously
single-sided in the new token, active at spot, and free for the maker.
The floor is enforced by the **absence** of liquidity below
`tickFloor`: sells cannot push price past it because there is nothing
on the other side to fill against. No hook, no custom curve, no
operator — just a position whose lower boundary is a wall.

### Design constants

| Constant       | Value | Notes |
|:---------------|:------|:------|
| `FEE`          | `100` | Uniswap's LOWEST canonical tier (0.01%); required for discovery by `smart-order-router`'s fallback enumeration. |
| `TICK_SPACING` | `1`   | Canonical pairing for the LOWEST tier; maximum granularity at the floor. |
| `HUB`          | `0xfFFFfF29e3C82351E7AaBE4C221dEfed6a803D5D` | Uniteum 1, same address on every chain. Mined with a high-`f` prefix so Lepton salt search almost always terminates at `salt = 0`. |
| `COINAGE`      | `0x14ae57AeD6AC1cd48Fa811Ed885Ab4a4c5e28C42` | Lepton, same address on every chain. |
| `POOL_MANAGER` | immutable | Uniswap V4 PoolManager, resolved at construction from an `IAddressLookup` passed in as a constructor argument. |

Unispring takes no constructor arguments. The bytecode is identical on
every chain it is deployed to, which lets it be deployed to a single
deterministic CREATE2 address everywhere.

## Patterns

`fund` is permissionless and can be called any number of times against
the same pool, by anyone, using their own tokens. Every position is
permanent. A few useful patterns fall out of that:

- **Staged emissions.** Fund an initial single-sided range covering
  early buyers; once price moves through it, call `fund` again with
  fresh supply at a higher range. Turns a one-shot launch into a
  ladder with no admin key.
- **Multi-tier launch ladder.** Split the initial supply across
  several `fund` calls at different tick ranges to shape the offering
  curve — some supply cheap, some expensive. A single range can't
  express "sell 30% below price X, 70% above" cleanly.
- **Permanent supply removal.** A holder who wants to sink tokens
  irrevocably can fund them as single-sided LP instead of sending to
  `0xdead`. Same effect on circulating supply, but the pool gets depth;
  for spoke deposits, any future buys convert the locked spoke into
  permanently locked hub.
- **Community-strengthened liquidity.** Third parties who care about a
  spoke can top up its floor without permission from the original
  funder. Equally applies to the hub: treasuries or whales can stack
  permanent hub sell-walls above spot as a credible commitment against
  unbounded pumps.
- **Re-arming a sold-out position.** Once the original single-sided
  range is fully crossed, the position is inert as a further seller.
  A fresh `fund` at a new range restarts distribution at the new
  market price.

Re-funds only settle when the new range sits entirely on the
single-sided side being added. For the hub (currency1-sided), `tickUpper`
must be at or below the current pool tick. For a spoke (currency0-sided),
`tickLower` must be at or above the current tick. In-range or wrong-side
re-funds revert at `settle`. See DESIGN.md §9 for the full argument.

## Comparison

| Property | Solid | Solid + UniSolid | Unispring |
|:---------|:------|:-----------------|:----------|
| Fair launch | Yes | Yes | Yes |
| Price floor | Yes | Yes | Yes |
| Maker capital required | None | None | None |
| Custom AMM | Yes | Yes | No |
| Uniswap tradeable | No | Via arbitrage | Native |
| DEX aggregator support | No | Indirect | Immediate |
| Chainlink dependency | No | Yes | No |
| Contracts required | 1 | 4 | 1 |
| Ongoing costs | None | Chainlink + gas | None |
| Swap fee | None | None | None |
| Cross-token routing | N/A | Via Uniswap | Two-hop via hub |

## Build

```bash
forge build
forge test
forge test -vvv   # verbose
```

## License

MIT
