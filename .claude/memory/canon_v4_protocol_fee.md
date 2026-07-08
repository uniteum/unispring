---
name: Uniswap V4 protocol fee — currently zero, capped at 0.1%
description: V4 charges no protocol fee today, but the PoolManager protocol-fee controller can set a per-pool fee up to 0.1% (1000 pips) per swap direction in the future.
type: project
---

Uniswap V4 has a built-in protocol fee mechanism that is **not currently
charging anything** but **could be turned on in the future, up to a
maximum of 0.1% per swap direction**.

**References:**

- `lib/v4-core/src/libraries/ProtocolFeeLibrary.sol:8` —
  `uint16 public constant MAX_PROTOCOL_FEE = 1000;` with the comment
  "Max protocol fee is 0.1% (1000 pips)". Pips denominator is
  `1_000_000`, so 1000 pips = 0.1%.
- `lib/v4-core/src/libraries/ProtocolFeeLibrary.sol:17-23` — fee is
  packed as two 12-bit values, one for zero-for-one and one for
  one-for-zero, so each direction can carry its own fee up to the cap.
- `lib/v4-core/src/interfaces/IProtocolFees.sol:33-37` — only the
  protocol-fee controller (set via `setProtocolFeeController`) may call
  `setProtocolFee` on a pool. Until a controller is configured and sets
  a non-zero value, every pool's protocol fee is 0.
- `lib/v4-core/src/libraries/ProtocolFeeLibrary.sol:38-46` — when a
  protocol fee is active, it is taken from the input first and the LP
  fee is taken from the remainder: `swapFee = protocolFee + lpFee -
  protocolFee*lpFee/1_000_000`.

**How to apply:**
- When reasoning or writing about Unispring fee economics, treat the V4
  protocol fee as zero today but flag the 0.1%-per-direction ceiling
  as a future possibility — don't claim "V4 has no protocol fee" without
  the qualifier.
- LP fee math in Unispring should not assume the swap fee equals the LP
  fee; the swap fee can grow by up to ~0.1% per direction if Uniswap
  governance later turns on the protocol fee.
- The cap is enforced by `isValidProtocolFee` in the same library; the
  PoolManager reverts with `ProtocolFeeTooLarge` if a controller tries
  to exceed it.
