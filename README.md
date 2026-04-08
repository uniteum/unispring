# Unispring

Fair-launch token factory on Uniswap V3 — permanent liquidity, built-in price floor, auto-compounding fees.

## Overview

Unispring creates tokens that are immediately tradeable on Uniswap V3
with fair-launch economics and a permanent price floor.

In a single transaction, the protocol:

1. Mints a fixed-supply ERC-20 token
2. Creates a Uniswap V3 pool (token/ETH)
3. Deposits 100% of the supply as concentrated liquidity
4. Locks the LP position permanently in the contract

No allocation. No presale. No operator.
The only way to acquire tokens is buying them from the pool.

## Why Unispring

### The problem with custom AMMs

Protocols like [Solid](https://uniteum.one/solid/) provide fair-launch
tokens with built-in liquidity and a permanent price floor. But
the liquidity lives in a custom AMM — isolated from the rest of DeFi.

Bridging that liquidity to Uniswap requires an external arbitrage
keeper ([UniSolid](https://github.com/uniteum/unisolid)), a Chainlink
Automation subscription, and ongoing gas costs. The result is four
moving parts where one should suffice.

### The Unispring approach

Unispring achieves the same economic properties — fair launch, price
floor, always tradeable — by deploying directly into Uniswap V3.

No custom AMM. No keeper. No arbitrage latency.

Tokens are immediately tradeable on any Uniswap frontend, DEX
aggregator, or smart contract that routes through Uniswap V3.

## Design

### Fair launch

The entire token supply starts in the Uniswap V3 pool.
No tokens are reserved for the creator.
The maker participates by buying from the pool like everyone else.

### Price floor

Concentrated liquidity on Uniswap V3 defines a price range.
The lower tick of the LP position sets a permanent price floor.

Because the LP position is locked in the contract with no withdrawal
function, the floor cannot be removed.

### Price dynamics

As tokens are bought out of the pool, the price rises along the
Uniswap V3 concentrated liquidity curve. Selling returns tokens
to the pool and lowers the price — but never below the floor.

### Auto-compounding fees

The Unispring contract holds the LP position and exposes a
permissionless `compound()` function. Anyone can call it to:

1. Collect accumulated trading fees
2. Add them back into the LP position

This deepens liquidity over time — more volume means deeper
liquidity means tighter spreads means more volume.

Callers receive a small percentage of the collected fees as
incentive, ensuring compounding happens without relying on
any centralized operator.

### Immutability

Uniswap V3 core contracts are immutable — no admin keys, no
upgrade proxy. A Unispring token deployed into a V3 pool inherits
that immutability.

The Unispring contract itself has:
- No owner
- No upgrade path
- No way to withdraw the LP position
- No governance parameters

Once a token is made, its rules are fixed.

## How it works

```
make(name, symbol)
        │
        ▼
┌──────────────────────┐
│  Mint fixed supply    │
│  Create V3 pool       │
│  Deposit 100% as LP   │
│  Lock LP position     │
└──────────────────────┘
        │
        ▼
  Token is live on
  Uniswap V3 — tradeable
  on any frontend or
  aggregator immediately
```

### Compounding

```
compound()  ← anyone can call
        │
        ▼
┌──────────────────────┐
│  Collect fees from    │
│  the LP position      │
│                       │
│  Pay caller reward    │
│                       │
│  Add remaining fees   │
│  back to the position │
└──────────────────────┘
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
| Custom AMM | Yes | Yes | No |
| Uniswap tradeable | No | Via arbitrage | Native |
| DEX aggregator support | No | Indirect | Immediate |
| Chainlink dependency | No | Yes | No |
| Contracts required | 1 | 4 | 1 |
| Ongoing costs | None | Chainlink + gas | None |
| Fee reinvestment | No | No | Auto-compound |

## Build

```bash
forge build
forge test
forge test -vvv   # verbose
```

## License

MIT
