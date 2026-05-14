---
name: bitsify
description: >-
  Convert a Solidity contract into a Bitsy contract — immutable,
  permissionless, governance-free, cloned, deterministic, direct,
  composable, and math-only. Use when the user wants to make a
  contract Bitsy or asks to apply the Bitsy pattern.
disable-model-invocation: true
argument-hint: "[path-to-contract] (defaults to file open in IDE)"
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

# Bitsify — Convert a Solidity contract to the Bitsy pattern

You are converting a Solidity contract into a **Bitsy** contract.

## What is a Bitsy contract

A **Bitsy contract** is a prototype/factory. Eight properties apply
to the **prototype**:

1. **Immutable** — prototype bytecode is frozen at deploy. No upgrade
   path, no admin key, no `selfdestruct`, no proxy repointing.
2. **Permissionless** — anyone can call `make()`. No `msg.sender`
   privilege checks on the factory surface or prototype-scope logic.
3. **Governance-free** — no voting, no adjustable parameters, no fee
   switch on the prototype itself.
4. **Cloned** — clones are EIP-1167 minimal proxies that delegate to
   the prototype's code.
5. **Deterministic** — addresses are computed via CREATE2 from a
   content-derived salt; `made()` predicts what `make()` will produce.
6. **Direct** — every factory operation is a single function call.
   No multi-step workflows beyond standard ERC-20 approvals.
7. **Composable** — exposes standard interfaces (`IPrototype` plus
   whatever the contract itself declares).
8. **Math-only** — no oracles or external data feeds in prototype-
   level logic; pricing comes from on-chain invariants.

These apply to the **prototype**. Clones may carry mutable
per-instance state, owners (mutable or immutable), or even internal
governance — the rules just have to be encoded in the prototype's
code once, not added post-deploy. Users of a clone consent to
whatever the prototype encodes.

The factory machinery (`proto` immutable, `make()`, `made()`, the
prototype-forward dance, `Unauthorized` error) is provided by the
shared `Prototype` base contract in `uniteum/proto`. A Bitsy contract
inherits it and overrides one virtual hook — `zzInit(bytes, uint256)`.
That is the entire mechanical change. The rest of this skill is about
the *non-mechanical* work: stripping things the prototype can't have
(access control, mutability, oracles, upgrade paths) — or, when the
input already lacks them, recognizing those steps as no-ops.

## Input

The input is a path to a Solidity contract file: `$ARGUMENTS`

If `$ARGUMENTS` is empty, fall back to the file currently open in the
IDE (provided via an `ide_opened_file` tag in your context). If
neither is available, ask the user for a path before proceeding.

## Step 0: Read and understand

Read the target contract. Before making any changes, identify:

- **Constructor parameters** — these become the args decoded inside
  `zzInit()` and the inputs to whatever typed wrapper you expose.
- **Access control** — `onlyOwner`, `Ownable`, role checks, `msg.sender`
  guards. Remove from prototype-level behavior. Per-clone access
  control (an owner gating setters on an individual clone) is fine
  so long as the mechanism is encoded in the prototype once and
  can't be added post-deploy.
- **Mutable parameters** — setters, governance hooks, adjustable fees,
  pause mechanisms. If they mutate prototype-level behavior, remove
  or bake in as constants. If they're per-clone (each instance's fee
  tunable by its owner, say), they may stay — the prototype's code
  still can't be changed.
- **Oracle dependencies** — external price feeds, Chainlink, TWAP.
  Flag these for the user — replacing oracles with invariant math
  requires a redesign and cannot be automated.
- **Upgrade mechanisms** — proxies, `delegatecall`, `selfdestruct`,
  UUPS, transparent proxy. These will be removed.

Present your analysis to the user before proceeding. Group findings
into:

1. **Mechanical changes** (you will handle these)
2. **Judgment calls** (mutable params that could be constants — ask
   the user what values to bake in)
3. **Design changes** (oracle replacement, architecture shifts — flag
   for the user, do not attempt without discussion)

Then classify the contract on the Bitsy spectrum. The classification
decides which steps below are no-ops and whether to take the fresh
or the migration path.

| Classification | Markers | Workflow |
| -------------- | ------- | -------- |
| **Already-`Prototype`** | imports `Prototype` from `proto/Prototype.sol` and inherits it | Report and exit — nothing to do |
| **Hand-rolled Bitsy** | one or more of: `address public immutable proto = address(this)` (or a domain alias like `HUB`/`NOTHING`/`MOB`), `make()` with an `address(this) == proto` forward branch, a `made()` view predictor, `zzInit()` with a `msg.sender != proto` check, a locally declared `error Unauthorized()` | [Step 0a](#step-0a-migration-path--hand-rolled-bitsy) migration path; skip Steps 4–7 |
| **Partial Bitsy** | none of the hand-rolled markers, but already lacks `Ownable`/setters/oracles/upgrade paths | Full conversion (Steps 1–3, 8); skip whichever of 4–7 are no-ops |
| **Non-Bitsy** | standard Solidity: `Ownable`, mutable params, possibly oracles or upgrade paths | Full conversion: Steps 1–7, then 8 |

A partial-match hand-rolled contract (some markers present, not all)
still takes the **migration path** — preserve what's there, add
what's missing. Routing a partial match through fresh conversion
creates collisions in [Step 1](#step-1-inherit-prototype) (the
inherited `proto` clashes with the locally declared one) and risks
re-stripping cleanup that's already been done.

State the classification explicitly to the user before proceeding,
so they can override it if your read of the markers is wrong.

## Step 0a: Migration path — hand-rolled Bitsy

If the contract is classified as **hand-rolled Bitsy** per the table
above, this is a **migration**, not a fresh conversion. The
prototype/access/mutability cleanup (Steps 4–7) was done when the
contract was first bitsified; only the factory boilerplate changes.
Partial-match cases (some hand-rolled markers, not all) still come
here — apply the migration steps below to whichever markers exist,
and treat any missing pieces as "already done."

The mechanical migration steps:

1. **Inherit `Prototype`.** Add the import and update the contract
   header. Interfaces come first, then base contracts ordered
   most-base to most-derived, so `Prototype` sits after any
   interfaces:

   ```solidity
   import {Prototype} from "proto/Prototype.sol";

   contract Foo is /* interfaces */, Prototype, /* other base contracts */ { ... }
   ```

2. **Delete the redeclared `proto` immutable.** It's inherited. If
   the contract used a domain-named alias (`HUB = this`, etc.), either
   keep the alias as a thin wrapper view (`function HUB() external view
   returns (Foo) { return Foo(proto); }`) or do a project-wide rename
   to `proto`. Pick one and apply consistently.

3. **Delete `error Unauthorized();`.** It's inherited from `IPrototype`.
   Watch for collisions with other interfaces (e.g. `ICoinage` used
   to declare its own `Unauthorized` — that has to go too if the
   contract inherits both).

4. **Rewrite `zzInit` to override the inherited bytes-form.** The
   typed `zzInit(typed args)` becomes:

   ```solidity
   function zzInit(bytes calldata args, uint256 variant)
       external override onlyProto
   {
       (Type1 p1, Type2 p2, ...) = abi.decode(args, (Type1, Type2, ...));
       // existing init body, unchanged
   }
   ```

   The base `Prototype.zzInit` is pure virtual (no body) and carries
   no modifier — apply `onlyProto` on the override yourself in place
   of the old hand-rolled `msg.sender != proto` check.

5. **Rewrite `make`/`made` as thin typed wrappers over the inherited
   bytes overloads** (see [Step 3](#step-3-optional-typed-makemade-wrappers)).
   Move all argument validation into a new `encode()` pure function.
   Delete the hand-rolled `address(this) == proto` forward — the
   inherited `Prototype.make` already handles it. If the contract has
   no typed surface worth preserving, you can drop the wrappers entirely
   and let callers use the inherited `make(bytes,uint256)` directly.

6. **Update tests.** Any test that called `zzInit(typed_args)` now
   calls `zzInit(abi.encode(typed_args), variant)`. Any test asserting
   `Foo.Unauthorized.selector` should switch to
   `IPrototype.Unauthorized.selector` (same selector value, but the
   `Foo.Unauthorized` reference no longer compiles).

### Salt-formula change

The legacy hand-rolled `made` computed:

```solidity
salt = keccak256(abi.encode(typed_args)) ^ bytes32(variant);
```

The inherited `Prototype.made(bytes,uint256)` computes:

```solidity
salt = keccak256(abi.encode(args_bytes)) ^ bytes32(variant);
// where args_bytes = abi.encode(typed_args)
```

The outer `abi.encode(args_bytes)` is Solidity's natural encoding of
a `bytes calldata` argument (offset ‖ length ‖ padded data) — so the
new hash differs from the legacy hash for the same typed inputs.

**Consequences:**

- **The prototype's own address changes** if anything in its bytecode
  shifts (which it will: new imports, new method table, possibly new
  compiler version). Existing on-chain prototypes are unaffected; new
  deployments will use a different address.
- **Every previously-mined clone variant becomes invalid.** Any
  `io/*/<addr>.{txt,yml}` artifacts for clones that haven't been
  broadcast yet need re-mining. Already-broadcast clones are pinned to
  their existing addresses — they don't move; only future clones
  computed offline will land somewhere different.

Flag both consequences to the user before proceeding. If there are
unbroadcast clones, ask whether to re-mine now or migrate later.

After the mechanical migration is done, skip to [Step 8: Verify](#step-8-verify).

## Layout rule

Order functions by visibility — `external` → `public` → `internal` →
`private` — per `solidity.md`. Within each visibility tier, place
business logic first and the factory-facing methods (`made`, `make`,
`zzInit`, `encode`, plus any private factory helpers) at the end of
that tier. The factory's externals (`made`, `make`, `zzInit`) sit at
the end of the external section; the `encode` helper sits at the end
of the public section; private factory helpers sit at the end of the
private section.

```
contract Foo is /* interfaces */, Prototype {
    // — state variables (no `proto` — that's inherited) —
    // — errors, events, modifiers —
    // — constructor (immutables and parent constructors only) —
    // — external business logic —
    // — external factory: made(), make(), zzInit() —
    // — public business logic —
    // — public factory: encode() —
    // — internal/private helpers (business first, factory last) —
}
```

Inheritance list order is interfaces first, then base contracts
ordered most-base to most-derived — `Prototype` (a base contract)
goes after the interfaces.

## Step 1: Inherit `Prototype`

Add the import and inheritance. Per `solidity.md`, interfaces come
first, then base contracts; `Prototype` is a base contract, so it
sits after any interfaces the contract declares:

```solidity
import {Prototype} from "proto/Prototype.sol";

contract Foo is /* interfaces */, Prototype, /* other base contracts */ { ... }
```

You get for free:

- `address public immutable proto = address(this);` — the prototype reference.
- `made(bytes32 argshash, uint256 variant)` — predict from a precomputed argshash.
- `made(bytes calldata args, uint256 variant)` — predict from raw args (hashes for you).
- `make(bytes calldata args, uint256 variant)` — deploys a clone if needed; when called on a clone, forwards to the prototype.
- `zzInit(bytes calldata args, uint256 variant)` — pure virtual hook (no body) that derived contracts must implement.
- `onlyProto` modifier and `Unauthorized` error — apply the modifier yourself on `zzInit` and any other clone-only entry points; the base does not carry it.

All three external entry points return `(bool exists, address home, bytes32 salt)`, so callers can tell whether a `make()` actually deployed something new.

**Do not redeclare** `proto`, `Unauthorized`, or any of the inherited
factory methods. Don't add your own `address(this) == proto` forward
in `make()` — `Prototype.make()` already handles the clone→proto
forward.

If you need to import `IPrototype` (e.g. for a natspec `@inheritdoc`
or to reference `IPrototype.Unauthorized.selector` in tests), it's at
`iproto/IPrototype.sol`.

## Step 2: Convert the constructor to `zzInit()`

### 2a: Empty the constructor

The constructor only runs on the prototype itself. It should only:

- Call parent constructors with fixed values
- Set immutables (these are baked into bytecode and shared by clones)

```solidity
constructor() ERC20("", "") {}
```

### 2b: Override `zzInit`

The base `Prototype.zzInit` is pure virtual: declared `external
virtual` with no body and no modifier. The override supplies the
init body and the access-control guard:

```solidity
/**
 * @inheritdoc IPrototype
 * @dev Decodes `(p1, p2, ...)` and applies them to clone storage.
 */
function zzInit(bytes calldata args, uint256 variant)
    external
    override
    onlyProto
{
    (Type1 p1, Type2 p2, ...) = abi.decode(args, (Type1, Type2, ...));
    // ... initialization logic from the old constructor ...
}
```

Apply `onlyProto` on the override — the base does not carry it, and
`zzInit` is `external`, so there is no `super.zzInit` to chain through
(and nothing to chain to: the base body is empty). If your init needs
to distinguish vanity-mined clones from each other, read `variant` in
the body; otherwise the parameter is unused (the unnamed `uint256`
form silences the warning, as in `Reflector` and `Fountain`).

### 2c: Handle ERC-20 metadata

If the contract is an ERC-20, name and symbol must be stored in
regular storage (not immutables) so clones can have distinct
metadata. Override `name()` and `symbol()` to read from storage:

```solidity
string internal _name;
string internal _symbol;

function name() public view override returns (string memory) {
    return _name;
}

function symbol() public view override returns (string memory) {
    return _symbol;
}
```

Set `_name` and `_symbol` inside `zzInit()`, not in the constructor.

## Step 3: (Optional) Typed `make`/`made` wrappers

The inherited `make(bytes,uint256)` is fully functional. Most Bitsy
contracts also expose a typed surface so callers don't have to
abi-encode by hand. The pattern:

1. A typed `made(...)` that delegates to `this.made(encode(...), variant)`.
2. A typed `make(...)` that calls `encode()`, then `this.make(args, variant)`
   on the inherited bytes overload.
3. An `encode()` pure function that validates and `abi.encode`s the
   per-clone init args (everything except `variant`).

Order them external-first per `solidity.md`: `made`, `make`, `zzInit`
sit in the external section; `encode` is `public` and sits in the
public section (after any public business logic) so that both wrappers
and external callers can reach it.

Example (cribbed from `Lepton`):

```solidity
function made(/* typed args */, uint256 variant)
    external view returns (bool exists, address home, bytes32 salt)
{
    (exists, home, salt) = this.made(encode(/* typed args */), variant);
}

function make(/* typed args */, uint256 variant)
    external returns (TypedReturn token)
{
    bytes memory args = encode(msg.sender, /* typed args */);
    (bool exists, address home,) = this.make(args, variant);
    token = TypedReturn(home);
    if (!exists) emit Made(msg.sender, token, /* typed args */);
}

function encode(address maker, string calldata name, string calldata symbol, uint8 decimals_, uint256 supply)
    public pure returns (bytes memory args)
{
    if (bytes(name).length == 0) revert Nameless();
    if (bytes(symbol).length == 0) revert Symbolless();
    if (supply == 0) revert Nothing();
    args = abi.encode(maker, name, symbol, decimals_, supply);
}
```

Notes:

- Put validation in `encode()` so both wrappers (and any external
  caller that wants to pre-encode) benefit. Don't sprinkle the same
  reverts in `make` and `made`.
- The typed `make` only uses `(bool exists, address home, ...)` from
  `this.make` — the third return (`salt`) is ignored by convention,
  but the trailing comma keeps the destructuring shape obvious.
- If the maker's identity should be baked into the clone's address
  (so different makers get different clones for the same inputs),
  include `msg.sender` in the encoded args. If clones should be
  globally unique by content, omit the maker.
- The typed `made` is deletable without touching `make` — `make`
  doesn't depend on it. That's the test for "thin wrapper".

### The variant parameter

Even with the inherited factory, `variant` is what makes clones
compatible with GPU-based vanity-address mining. Internally
`Prototype.made` computes `salt = keccak256(abi.encode(args)) ^ variant`,
where `args` is the `bytes` blob passed to `make`. Mining varies
`variant` and re-derives the address until it matches a target mask.

The standard mining workflow uses `saltminer`:

```bash
saltminer \
  --deployer     <prototype address>    # the factory, not Nick
  --initcodehash <keccak of EIP-1167 stub keyed to prototype>
  --argshash     <keccak(abi.encode(args_bytes))>   # note: double encoding
  --mask         0xffff...0000           # bits the address must match
  --target       0xfeed...0000           # target value under the mask
```

The `--argshash` is `keccak256(abi.encode(args_bytes))` where
`args_bytes` is itself the abi-encoded typed args — a "double
encoding" relative to the legacy hand-rolled flat hash. Use crucible's
`clone_predict` (in `lib/crucible/script/clone.sh`) to compute it
correctly.

For prototype contracts deployed via Nick rather than via a Bitsy
factory, the caller mines the CREATE2 salt directly — `variant`
applies only to clones produced through `make()`.

See [crucible/docs/deployment.md](../../../docs/deployment.md) for
how mined variants are committed alongside the rest of the
deployment artifacts and how `deploy.sh` consumes them.

## Step 4: Strip prototype-level access control

Access control on the **prototype** must go. Remove anything that
gates the factory surface or the prototype's own behavior:

- `Ownable`, `AccessControl`, and similar inheritance on the prototype
- `onlyOwner` / `onlyRole` / `onlyAdmin` modifiers on `make()`,
  `zzInit()`, or prototype-scope business functions
- `renounceOwnership()`, `transferOwnership()` at prototype scope
- Any `require(msg.sender == ...)` gating prototype-level behavior

**Per-clone access control is allowed.** Each clone may have its own
owner (mutable or immutable) gating its own setters, as long as the
ownership mechanism is encoded in the prototype's code and assigned
at `zzInit()` time. The prototype is still permissionless; per-clone
users consent to the rules by choosing to `make()` one.

**Clone-identity checks** are also acceptable — not privilege checks
but coordination guards, preventing arbitrary external contracts
from calling internal prototype/clone coordination functions. Pattern:

```solidity
modifier onlyClone() {
    if (msg.sender == proto) {
        _;
        return;
    }
    // Verify caller is a valid clone deployed by this prototype
    (, address expected,) = this.made(/* caller's args */, /* variant */);
    if (msg.sender != expected) revert Unauthorized();
    _;
}
```

## Step 5: Strip prototype-level mutability

Prototype-level behavior must be frozen. Remove anything that mutates
the prototype itself or rules shared by every clone:

- Setters on prototype-scope state
- Pause/unpause of the factory (`whenNotPaused` on `make()`, etc.)
- Emergency functions on the prototype (`emergencyWithdraw`,
  `shutdown`)
- Governance over prototype-level parameters
- Prototype-wide fee switches, tunable globals, upgradeable references

**Per-clone mutability is allowed.** A clone may have setters its
owner can call, internal governance (voting, quorum), or pause/unpause
of its own behavior — as long as the machinery is baked into the
prototype's code. Mob is the canonical example: each mob has its own
voters, proposals, and quorum; the Mob prototype has none.

For each prototype-level mutable parameter you remove, either:

- **Bake it in as a constant** (ask the user for the value), or
- **Remove the feature entirely** if it doesn't make sense as a
  fixed value.

## Step 6: Strip upgrade mechanisms

Remove:

- UUPS, transparent proxy, beacon proxy patterns
- `selfdestruct` / `SELFDESTRUCT` opcode usage
- `delegatecall` to mutable targets
- Storage gaps (`__gap`)
- Initializable guards from OpenZeppelin's upgradeable contracts
  (replace with the simpler `zzInit` pattern)

## Step 7: Flag oracle dependencies

If the contract uses external data feeds (Chainlink, Uniswap TWAP,
custom oracles), **do not silently remove them**. Instead:

1. List every oracle dependency found.
2. Explain what each oracle provides.
3. Ask the user how they want to replace each one — options include:
   - Constant-product AMM invariant (`x * y = k`)
   - Geometric mean invariant (`w = sqrt(u * v)`)
   - Fixed rate baked into the contract
   - Removal of the feature that required the oracle
4. Do not proceed with oracle replacement without explicit guidance.

## Step 8: Verify

All eight properties apply to the **prototype**. Clone-level behavior
is governed by whatever the prototype encodes — if it's there by
design, it's fine.

1. **Immutable** (prototype): No upgrade mechanism on the prototype,
   no admin key controlling prototype behavior, no proxy repointing,
   no `selfdestruct`. Clones can't be upgraded either, since they
   delegate to the prototype's code.
2. **Permissionless** (factory): Anyone can call `make()`. No
   `msg.sender` privilege checks on the factory surface or
   prototype-scope functions. Per-clone owners gating per-clone
   setters are fine. Clone-identity checks are fine.
3. **Governance-free** (prototype): No voting or adjustable parameters
   on the prototype. Per-clone governance (Mob-style) is fine.
4. **Cloned**: Inherits `Prototype`, which uses EIP-1167 minimal
   proxies via OpenZeppelin's `Clones`.
5. **Deterministic**: Inherited `make()` uses CREATE2 with
   content-derived salt; inherited `made()` predicts the address
   from the same inputs. They agree on `home` from any caller —
   `Prototype.make()` forwards from clones back to the prototype.
6. **Direct**: Every factory operation is a single function call. No
   multi-step workflows on the prototype beyond standard ERC-20
   approvals.
7. **Composable**: Prototype exposes standard interfaces (`IPrototype`
   plus whatever the contract itself declares). Clones present standard
   interfaces (e.g. ERC-20) where applicable.
8. **Math-only** (prototype): No oracles or external data feeds in
   prototype-level logic. Pricing that applies to all clones is
   determined by on-chain invariants. Per-clone oracle use is a
   design choice the prototype encodes.

Report any property that cannot be satisfied and explain why.

## Output

Present the transformed contract to the user. Summarize:

- What was changed mechanically
- What was baked in (and at what values)
- What was removed
- What still needs design work (oracles, architecture)
