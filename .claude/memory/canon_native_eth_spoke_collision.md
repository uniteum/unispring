---
name: Native-ETH spoke collides with Unispring's hub-vs-ETH pool
description: A Unispring native-ETH spoke seats into the same V4 pool as the hub's own ETH pool, so it only succeeds when the spoke's V4 lower-edge price matches the hub pool's init tick.
type: project
---

In Unispring, `offer(token, ...)` picks the quote currency by checking
`token == hub`: if not the hub, the quote is the hub. So a native-ETH
spoke (`token = Currency.wrap(address(0))`) against an ERC-20 hub
produces the pool key `(ETH, hub)` — the exact same currency pair as
the hub's own ETH pool that `zzInit` already initialized.

Concretely: `zzInit` calls `offer(hub, supply, HUB_TICK_LOWER,
HUB_TICK_UPPER)` with `isHub = true`, which negates and swaps the user
ticks (`ticks[0] = -tickUpper`, `ticks[1] = -tickLower`) and pairs
against ETH. After Fountain's flip-handling (hub > ETH so hub becomes
currency1), the V4 pool initializes at tick `HUB_TICK_UPPER`.

A subsequent ETH-as-spoke `offer` call hits the same pool. ETH
< hub so no flip; Fountain initializes at `tickLower` user-tick. The
two prices only match when `tickLower == HUB_TICK_UPPER`. Any other
spoke `tickLower` reverts with `Fountain.PoolPreInitialized` because
the pool already exists at the hub's init price.

**Why:** Unispring's hub-and-spoke design assumes spokes pair against
the hub *token* (which the hub itself doesn't do — it pairs against
ETH). Native-ETH spoke is a degenerate case where spoke and hub-quote
collapse to the same currency, so the spoke pool *is* the hub pool.

**How to apply:**
- Don't suggest native-ETH spokes as a typical Unispring use case.
- If a test or call needs to exercise the native-spoke path, pin
  `tickLower = HUB_TICK_UPPER` (V4 terms, no flip) so the price
  matches and Fountain's matched-price branch skips re-init. See
  `test_FundSeatsNativeETHSpokeAgainstHub` in `test/UnispringFork.t.sol`.
- The collision is structural, not a bug. No code fix is warranted
  unless Unispring's design is rethought to allow non-hub-quoted
  spokes.
