---
name: predict
description: Generate or migrate an io/<Contract>/<Contract>.sh deployment script for a Bitsy contract. Determines whether the contract is a prototype (deployed via Nick) or a clone (deployed via another Bitsy prototype's make()), then writes the appropriate proto_predict / clone_predict call. Use when the user asks to create a deployment script for a contract, or to migrate a legacy script/<Contract>.sh forge script.
allowed-tools: Read, Bash, Write, Edit, Grep
argument-hint: <ContractName>
---

# Predict — generate a Bitsy deployment script

The input is a contract name: `$ARGUMENTS`

You are producing `io/<Contract>/<Contract>.sh` — a thin wrapper around
crucible's `proto_predict` (for prototypes) or `clone_predict` (for
clones). When the script runs, it writes `<addr>.{txt,yml,json}` next
to itself; `deploy.sh` and `verify.sh` consume those artifacts.

## Step 0: Identify whether prototype or clone

Read `src/<Contract>.sol`. Two possibilities:

- **Prototype.** The contract has a `make()` factory function and is
  itself the implementation that future clones delegate to. Deployed
  once via Nick's deterministic deployer
  (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with a chosen salt.
  Examples in the Uniteum tree: `Lepton`, `AddressLookup`,
  `StringLookup`, `Fountain`, `Manifold`, `Mimicry`.
- **Clone.** Deployed by some other Bitsy prototype's `make()` call.
  No `make()` of its own (or `make()` only forwards to proto). Has
  `zzInit(...)`. Examples: `PoolManagerLookup` (clone of
  `AddressLookup`), `Fountain1` (clone of `Fountain`), `GasNameLookup`
  (clone of `StringLookup`).

A Bitsy prototype that mints clones of *itself* (like `Fountain`) is
still a prototype. The clones it produces (e.g. `Fountain1`) are what
get a `clone_predict` call.

If the user names a contract that is the *prototype's source file*
but they want the **clone** script, name the clone something
recognizable (`Fountain1`, `PoolManagerLookup`, etc.).

## Step 1: Read the relevant signatures

**Prototype.** Find the `constructor(...)` signature. Each parameter
becomes a `proto_predict` argument. Address-typed parameters typically
point at upstream Bitsy contracts and should be hardcoded with
provenance comments.

**Clone.** Find the prototype's `made(...)` and `make(...)` functions.
The args before the trailing `uint256 variant` are what's hashed for
the salt. The contract's salt derivation is something like:

```solidity
salt = keccak256(abi.encode(<args>)) ^ bytes32(variant);
```

`clone_predict` takes those args (as a Solidity-style type signature
and matching values), the variant, and the prototype's address.

## Step 2: Choose a salt or variant

The user may already have one (mined). If not:

- Pass `0x0...0` as the salt/variant if no vanity is wanted.
- Otherwise, the script can be written with a placeholder; tell the
  user they need to mine. The mining recipe is in
  [`crucible/.claude/rules/deployment.md`](../../rules/deployment.md)
  and the saltminer flag mapping is in
  [`lib/crucible/docs/deployment.md`](../../../docs/deployment.md).

If `mask` and `target` are documented anywhere (a comment in a legacy
script, the user, etc.), capture them as env vars in the new script —
proto.sh / clone.sh write them into the yml for reproducibility.

## Step 3: Templates

### Prototype

```bash
#!/usr/bin/env bash
# <Contract> — <one-line summary from the contract's NatSpec>.
# Cross-repo deps (if any):
#   <UpstreamContract> ← <repo>/io/<UpstreamContract>/
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

# Constructor args (hardcoded; update when any upstream is re-predicted).
UpstreamA=0x...
UpstreamB=0x...

# Optional vanity-mining metadata.
# mask=0xfff000000000000000000000000000000000ffff
# target=0xabc000000000000000000000000000000000e220

proto_predict <Contract> 0xSALT \
    "constructor(address,address)" "$UpstreamA" "$UpstreamB"
```

For a no-arg constructor, drop the signature and the trailing args:

```bash
proto_predict <Contract> 0xSALT
```

### Clone

```bash
#!/usr/bin/env bash
# <Clone> — clone of <Prototype>.
# <Prototype>'s make computes
#   salt = keccak(abi.encode(<args>)) ^ variant
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

deployer=0x...   # the Bitsy prototype that mints this clone

# Make-call args (used for both the argshash and the calldata).
some_arg=0x...

# Optional vanity-mining metadata.
# mask=0xfff...ffff
# target=0xabc...e220

clone_predict <Clone> "$deployer" \
    "<argsType>" "$some_arg" \
    0xVARIANT
```

`<argsType>` is the Solidity type signature (without the trailing
`,uint256` for variant). Common patterns:

| Make signature                                  | argsType                |
|-------------------------------------------------|-------------------------|
| `make(address owner, uint256 variant)`          | `address`               |
| `make(KeyValue[] kvs, uint256 variant)`         | `(uint256,address)[]`   |
| `make(KeyValue[] kvs, uint256 variant)` (string)| `(uint256,string)[]`    |

## Step 4: Place the script

If a legacy `script/<Contract>.sh` exists, migrate via `git mv`:

```bash
git mv script/<Contract>.sh io/<Contract>/<Contract>.sh
```

then overwrite the body using the template. Preserve the legacy salt /
variant / mask / target / addresses where they still apply — note that
upstream address changes invalidate previously-mined vanity salts.

If no legacy script exists, write the file fresh; the io directory is
created automatically by the `proto_predict` / `clone_predict` helper.

## Step 5: Suggest next steps

After writing the script, tell the user (concisely):

1. `bash io/<Contract>/<Contract>.sh` — generates `<addr>.{txt,yml,json}`.
2. If the salt/variant is `0x0` or known-stale, re-mine using the
   `initcodehash` (and `argshash` for clones) the script prints.
3. `git add` the script and the new artifacts.
4. Deploy with `bash lib/crucible/script/deploy.sh <chain> <addr>`
   (dry-run; pass `-b` to broadcast).
5. Verify with `bash lib/crucible/script/verify.sh <chain> <addr>`.

## Output

Show the user what was created or migrated. Highlight any TBD
placeholders that still need manual values (e.g. cross-repo addresses
that haven't been deployed yet, mined salt, owner address).
