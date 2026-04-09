# Unispring

Fair-launch token factory on Uniswap V4 — permanent liquidity, built-in
price floor, zero maker capital, auto-compounding fees.

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

### Auto-compounding fees

The Unispring factory holds every position it creates and exposes a
permissionless `compound(poolId)` function. Anyone can call it to:

1. Collect accumulated trading fees from the position
2. Pay the caller a fixed percentage of the collected fees
3. Add the remainder back into the same position

This deepens liquidity over time — more volume means deeper liquidity
means tighter spreads means more volume. The caller reward ensures
compounding happens without any centralized operator.

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

## How it works

```
make(name, symbol, supply, tickFloor)
        │
        ▼
┌──────────────────────────────┐
│  Lepton mints fixed supply    │
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

### Compounding

```
compound(poolId)  ← anyone can call
        │
        ▼
┌──────────────────────────────┐
│  Collect fees from position   │
│  Pay caller fixed reward      │
│  Add remainder back in        │
└──────────────────────────────┘
        │
        ▼
  Liquidity deepens,
  spreads tighten
```

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
| Fee reinvestment | No | No | Auto-compound |
| Cross-token routing | N/A | Via Uniswap | Two-hop via hub |

## Build

```bash
forge build
forge test
forge test -vvv   # verbose
```

## License

MIT
