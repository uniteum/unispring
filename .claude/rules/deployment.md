---
paths:
  - "**"
---

# Deployment

This repo's contracts are deployed using crucible's predict-and-commit
pipeline, **not** the legacy `forge script` (`*.s.sol`) pattern. New
deployment scripts go under `io/<Contract>/<Contract>.sh`, source the
appropriate crucible helper, and let `deploy.sh` broadcast.

If asked to write a `DEPLOY.md`, README deployment section, new
`<Contract>.sh`, or any other deployment artifact: follow this pattern.
Do **not** suggest `forge script src/<X>.s.sol --broadcast` workflows
unless the user explicitly asks about the legacy approach.

## Per-contract scripts

A prototype (`kind: prototype`, deployed via Nick's CREATE2 deployer):

```bash
#!/usr/bin/env bash
# Lepton — Bitsy coinage prototype.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/proto.sh"

# Optional vanity-mining metadata captured into the yml.
mask=0xfff000000000000000000000000000000000ffff
target=0x1eb000000000000000000000000000000000e220

proto_predict Lepton 0x000000000000000000000000000000000000000000000000000000002b3fbfee \
    "constructor(address)" "$SomeArg"   # signature + values; omit for no-arg
```

A clone (`kind: clone`, deployed via a Bitsy prototype's `make()`):

```bash
#!/usr/bin/env bash
# Fountain1 — Bitsy clone of Fountain.
set -euo pipefail
source "$(git rev-parse --show-toplevel)/lib/crucible/script/clone.sh"

deployer=0x...   # the prototype that mints this clone

clone_predict Fountain1 "$deployer" \
    "address" "$owner" \
    0x...mined_variant...
```

Running these scripts writes `io/<Contract>/<addr>.{txt,yml,json}`
(`.json` is omitted for clones — Etherscan auto-detects EIP-1167
proxies and inherits the prototype's verified source).

## yml schema

The yml is the metadata source of truth. Hex values are double-quoted
to keep YAML editors from mangling them as numeric literals.

```yaml
contract: Mimicry
kind: prototype
deployer: "0x4e59b44847b379578588920cA78FbF26c0B4956C"
initcodehash: "0x..."
salt: "0x..."
compilerversion: "v0.8.30+commit.73712a01"
license: "MIT"
mask: "0x..."        # optional, vanity-mining inputs
target: "0x..."
args:                 # constructor args (proto only); used by deploy.sh
  - "0x...Fountain1"
  - "0x...ICoinage"
  - "0x...GasNameLookup"
home: "0x..."
```

## Deploy

`deploy.sh` walks both the deployer chain and any addresses listed
under `args:` that have ymls of their own. Sibling repos under `../*/`
are searched for cross-repo deps without needing them as submodules.

```bash
# Dry-run (default): walks the dep chain and prints what would deploy
bash lib/crucible/script/deploy.sh <chain> <addr>

# Broadcast (any cast wallet flag is forwarded to cast send)
bash lib/crucible/script/deploy.sh -b --account dev <chain> <addr>
bash lib/crucible/script/deploy.sh -b --ledger <chain> <addr>
tx_key=0x... bash lib/crucible/script/deploy.sh -b <chain> <addr>
```

## Verify

`verify.sh` submits the committed `<addr>.json` directly to
Etherscan v2 — does **not** call `forge verify-contract`, which would
regenerate the standard input from current source and break verification
once the source drifts.

```bash
ETHERSCAN_API_KEY=... bash lib/crucible/script/verify.sh <chain> <addr>
```

For prototypes only — clones are auto-detected by Etherscan as EIP-1167
proxies, so verifying the prototype is sufficient.

## Full detail

[`lib/crucible/docs/deployment.md`](../docs/deployment.md) is the
canonical reference for the design and yml schema.
