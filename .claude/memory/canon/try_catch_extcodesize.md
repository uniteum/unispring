---
name: try-catch-extcodesize
description: Solidity try/catch does NOT catch the EXTCODESIZE check for typed external calls — must guard no-code targets explicitly
metadata:
  type: project
---

In Solidity 0.8.34 (and likely all current versions), a typed external
call like `try IAddressLookup(peg_).value() returns (...)` does **not**
catch the "call to non-contract address" revert when `peg_` has no code.

The compiler emits an EXTCODESIZE check around the call's return-data
decode that reverts *outside* the try frame, so the catch block never
runs.

**Why:** Confirmed empirically in `Reflector._resolve` — removing the
`if (peg_ == address(0)) return address(0);` guard made
`test_ProtoIsETHFactory`, `test_MakeNativeETH`, and
`test_MakeNativeETHWithNonProtoSymbol` revert with "call to non-contract
address" even though the call site was inside a `try/catch`.

**How to apply:** When resolving optional / sentinel addresses through a
`try`-style interface call, always guard `address(0)` (and any other
known-no-code address) explicitly *before* the try. Do not assume the
catch covers it. The `peg_.code.length == 0` short-circuit is the
correct general pattern; the `address(0)` literal check is a cheap
special case for the common sentinel.
