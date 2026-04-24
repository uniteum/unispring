# Unispring

Fair-launch token factory on Uniswap V4 — permanent liquidity, built-in
price floor, zero maker capital.

## Overview

Unispring creates tokens that are immediately tradeable on Uniswap V4
with fair-launch economics and a permanent price floor.

In a single transaction, the `NeutrinoSource` wrapper:

1. Mints a fixed-supply ERC-20 token via [Coinage](https://github.com/uniteum/lepton)
2. Initializes a Uniswap V4 pool against the hub token
3. Deposits 100% of the supply as a single-sided concentrated position
4. Locks the position permanently in a `Fountain` clone

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

The hub is the key of each Unispring clone: one clone per
`(hub, tickLower, tickUpper)` triple. The canonical deployment uses
[Uniteum 1](https://uniteum.one/uniteum-1/) as its hub.

## Design

### Fair launch with zero maker capital

The entire token supply starts in the Uniswap V4 pool as a single-sided
position. The maker provides **no hub tokens** — only gas. There is no
founder bag because there is no founder deposit.

The maker participates by buying from the pool like everyone else.

### Price floor

The seeded position spans `[tickLower, tickUpper]`, and the pool's
initial price is set exactly at `tickLower`. Two consequences follow:

- The position is single-sided in the new token, requiring zero hub
  tokens to seed.
- Below `tickLower` there is no liquidity at all. Sells cannot push the
  price past it because there is nothing on the other side to fill
  against. The floor is enforced by the **absence** of liquidity, not
  by a hook or custom curve.

`tickLower` is chosen by the funder at `offer()` time and is permanent.

### Price dynamics

As tokens are bought out of the pool, price rises along the
concentrated-liquidity curve and hub tokens accumulate in the position.
Selling returns tokens to the pool and lowers the price — but never
below the floor. The position extends from `tickLower` to `tickUpper`,
both chosen by the funder at fund time.

### Low fee

Pools are created at `fee = 100` (0.01%, Uniswap's lowest canonical
tier). Swap fees accrue inside the position and are claimable by a
single `taker` address — the `msg.sender` that first called
`Fountain.make()`. `taker` has no other authority: it cannot pause,
cannot withdraw principal, cannot modify ticks.

Fees are not reinvested and not paid out to LPs (there are no LPs —
every position is permanently owned by a `Fountain` clone with no
withdraw path). The depth of a pool is whatever was funded plus
whatever follow-on `offer` calls add.

### Bitsy factory, per-hub clones

Unispring is a prototype plus a family of deterministic clones, one
per `(hub, tickLower, tickUpper)` triple. Each clone pairs its single
hub against any number of spokes via `offer()`. Clones share no state.

No clone has:

- An owner
- An upgrade path
- A way to withdraw any position
- Any governance parameters

Positions themselves live one level deeper, on a `Fountain` — a
separate contract that owns every V4 position Unispring seats. Once
a token is funded, its rules are fixed.

### Immutability

Uniswap V4's `PoolManager` is immutable — no admin keys, no upgrade
proxy. Lepton (the ERC-20 implementation Coinage deploys) is immutable.
Fountain, Unispring, NeutrinoChannel, and NeutrinoSource are all
immutable. A token deployed through this stack inherits immutability
from end to end.

### Trust boundaries

NeutrinoSource, NeutrinoChannel, and Unispring are **factories**.
Their job is to mint a token, initialize a pool, and lock a single-sided
position. Once that work is done, none of them has any authority over
what they created. Fountain owns the position that results, but exposes
no method to withdraw, collect principal, or modify ticks — only the
fee-forward path to `taker`.

The ongoing behavior of a launched token is split across:

| After launch, ...                  | ... is governed by                                                |
|:-----------------------------------|:------------------------------------------------------------------|
| Token transfers, approvals, supply | Lepton (the ERC-20 implementation)                                |
| Swap math, pool state, liquidity   | The Uniswap V4 PoolManager — plus any DEX router that reaches it  |
| Accrued swap fees                  | Fountain (forwards to `taker` on demand; no other authority)      |

Concretely:

- **NeutrinoChannel** relays one `Coinage.make()` call per clone and
  transfers the minted supply to its caller. After `mint()` returns,
  it holds no tokens and has no privileged relationship with the one
  it just minted.
- **NeutrinoSource** composes a channel-minted hub with a Unispring
  clone at `make()`, then on each `launch()` mints a spoke and hands
  it to Unispring for funding. The clone retains no claim on either
  token or on the pool.
- **Unispring** pre-approves Fountain against the pulled tokens and
  calls `Fountain.offer()` to seat a permanent single-sided position.
  The clone retains no claim on the position.
- **Fountain** holds every seated position in a registry keyed by
  position id. It exposes `take` (forwards accrued fees to `taker`)
  but no decrease-liquidity path — principal is locked forever.

So the security surface a maker or holder needs to reason about is
narrow: **Lepton** (does the ERC-20 behave correctly?), **Fountain**
(are the positions really permanent?), and **Uniswap V4** (does the
pool honor its stated math?). The factories above them are one-shot
and step aside.

## How it works

One-shot fair launch via NeutrinoSource:

```
neutrinoSource.launch(name, symbol, decimals, supply, salt, tickLower, tickUpper)
        │
        ▼
┌──────────────────────────────────┐
│  Coinage mints fixed supply      │
│  at a CREATE2 address that       │
│  sorts strictly below the hub    │
│  Transfer supply to Unispring    │
│  clone; clone calls Fountain     │
│  Fountain initializes V4 pool    │
│  at `tickLower`, seats supply    │
│  single-sided in [lower, upper)  │
│  Position locked in Fountain     │
└──────────────────────────────────┘
        │
        ▼
  Token is live on Uniswap V4 —
  tradeable on any frontend or
  aggregator immediately
```

Bare-bones flow (no Coinage wrapper): deploy an ERC-20 whose address
sorts below the hub, transfer any amount to a `Unispring` clone, then
call `clone.offer(token, supply, tickLower, tickUpper)`. Same end state,
no mint step.

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
the funder doesn't need to supply any hub.

Those two requirements *can* both be satisfied, but only at the **lower
boundary** of a range, where the conventions align. So the position
must be shaped so that the new token sits on the side corresponding to
that lower-boundary seed: the new token must be `currency0`, the range
must be `[tickLower, tickUpper]` with `tickLower` as the floor, and
the pool must be initialized at exactly `sqrtPrice(tickLower)`.

The mirror configuration — new token as `currency1`, seeded at the
upper boundary of `[MIN_TICK, -tickLower]` — looks symmetric but
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

Coinage accepts a caller-supplied `salt` for its CREATE2 deployment,
and exposes a pure `made()` view so addresses can be predicted
off-chain without spending gas. The maker runs a small loop:

```
for salt in 0, 1, 2, ...:
    addr = coinage.made(deployer, name, symbol, decimals, supply, salt).home
    if addr < hub:
        break
```

and then calls `neutrinoSource.launch(name, symbol, decimals, supply,
salt, tickLower, tickUpper)` with the winning salt. `Unispring.offer`
reverts with `SpokeMustSortBelowHub(token)` if the constraint isn't
met.

The expected number of salts to try is
`addressSpace / (addressSpace - hubValue)` — i.e. the smaller the hub
address, the more tries. This is why the canonical hub is deployed at
an address with several leading `f` bytes: it makes the search
succeed on the first try for almost every `(name, symbol, decimals,
supply)` combination, so in practice callers submit `salt = 0` and
never think about it. The cost of mining a "big" hub address is paid
**once**, at hub deployment, and amortized across every Unispring
token that will ever be created.

#### Summary

The position spans `[tickLower, tickUpper]`. The pool's initial tick
is exactly `tickLower`. The new token is `currency0`, the hub is
`currency1`. This is the only configuration that is simultaneously
single-sided in the new token, active at spot, and free for the funder.
The floor is enforced by the **absence** of liquidity below
`tickLower`: sells cannot push price past it because there is nothing
on the other side to fill against. No hook, no custom curve, no
operator — just a position whose lower boundary is a wall.

### Design constants

| Constant                 | Value   | Notes |
|:-------------------------|:--------|:------|
| `Fountain.FEE`           | `100`   | Uniswap's LOWEST canonical tier (0.01%); required for discovery by `smart-order-router`'s fallback enumeration. Swap fees accrue to Fountain's `taker`. |
| Spoke `tickSpacing`      | caller-supplied | Unispring passes `tickSpacing = 1` to Fountain today (maximum granularity at the floor). |
| `Fountain.POOL_MANAGER`  | immutable | Uniswap V4 PoolManager, resolved at Fountain construction from an `IAddressLookup`. |
| `Unispring.FOUNTAIN`     | immutable | The Fountain every Unispring pool is seated on; chosen by whoever deployed the Unispring prototype. |

Each protocol contract is bytecode-addressed via CREATE2 through a
shared `CREATE2_FACTORY`, so the same prototype deploys at the same
address on every chain it is launched to.

## Patterns

`offer` is permissionless and can be called any number of times against
the same pool, by anyone, using their own tokens. Every position is
permanent. A few useful patterns fall out of that:

- **Staged emissions.** Fund an initial single-sided range covering
  early buyers; once price moves through it, call `offer` again with
  fresh supply at a higher range. Turns a one-shot launch into a
  ladder with no admin key.
- **Multi-tier launch ladder.** Split the initial supply across
  several `offer` calls at different tick ranges to shape the offering
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
  A fresh `offer` at a new range restarts distribution at the new
  market price. Third parties can also LP directly into the same pool
  via the PoolManager, or open a parallel pool at a different fee
  tier — see DESIGN.md §14 for the full catalog of post-buyout
  options.

Re-offers are doubly constrained. First, Fountain requires the batch's
starting tick to correspond exactly to the current pool price — if
it doesn't, the call reverts with `PoolPreInitialized`. Second, for
the batch to seat single-sided, the range must sit entirely on the
side being added: for a spoke (currency0-sided) that means
`ticks[0]` equals the current pool tick and the range extends
upward; for the hub (currency1-sided) that means `ticks[0]` equals
the current pool tick and the (user-semantic) range extends downward.
In-range or wrong-side re-offers revert. See DESIGN.md §9 for the full
argument.

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
| Swap fee | None | None | 0.01% (to Fountain taker) |
| Cross-token routing | N/A | Via Uniswap | Two-hop via hub |

## Build

```bash
forge build
forge test
forge test -vvv   # verbose
```

## License

MIT
