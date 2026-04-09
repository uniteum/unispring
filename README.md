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

### Token ordering and the floor

Lepton deploys each token at a CREATE2 address derived from
`(maker, name, symbol, supply)` — the maker cannot choose which side of
the hub the new token's address falls on. Unispring handles both
orderings inside `make()`:

- If `newToken < hub`, the new token is `currency0`. The position is
  `[tickFloor, MAX_TICK]` and the pool's initial tick is `tickFloor`
  (the lower bound), so the position holds only `currency0`.
- If `newToken > hub`, the new token is `currency1`. The position is
  `[MIN_TICK, -tickFloor]` and the pool's initial tick is `-tickFloor`
  (the upper bound), so the position holds only `currency1`.

The maker passes `tickFloor` in **new-token-priced-in-hub** semantics —
i.e. as if the new token were always `currency0` and the hub were
`currency1`. The contract translates that to the pool's native tick
orientation based on the address ordering. Both code paths produce
identical economic floors.

### Design constants

| Constant       | Value | Notes |
|:---------------|:------|:------|
| `FEE`          | `0`   | No swap fee. |
| `TICK_SPACING` | `1`   | Maximum granularity at the floor. |
| `HUB`          | `0x7d5b1349157335aeEb929080A51003B529758830` | Uniteum 1, same address on every chain. |
| `COINAGE`      | `0x14ae57AeD6AC1cd48Fa811Ed885Ab4a4c5e28C42` | Lepton, same address on every chain. |
| `POOL_MANAGER_LOOKUP` | `0xd6185883DD1Fa3F6F4F0b646f94D1fb46d618c23` | Per-chain `IAddressLookup` resolving the V4 PoolManager. |

Unispring takes no constructor arguments. The bytecode is identical on
every chain it is deployed to, which lets it be deployed to a single
deterministic CREATE2 address everywhere.

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
