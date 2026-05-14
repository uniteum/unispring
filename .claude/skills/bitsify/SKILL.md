---
name: bitsify
description: >-
  Convert a Solidity contract into a Bitsy contract — immutable,
  permissionless, governance-free, cloned, deterministic, direct,
  composable, and math-only. Use when the user wants to make a
  contract Bitsy or asks to apply the Bitsy pattern.
disable-model-invocation: true
argument-hint: <path-to-contract>
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

# Bitsify — Convert a Solidity contract to the Bitsy pattern

You are converting a Solidity contract into a **Bitsy** contract.

A **Bitsy contract** is a prototype/factory. The prototype satisfies
eight properties: immutable, permissionless, governance-free, cloned,
deterministic, direct, composable, and math-only.

Clones delegate to the prototype's code via EIP-1167, so they can't
be upgraded — but they may carry mutable per-instance state, owners
(mutable or immutable), or even internal governance. The control
plane has to be baked into the prototype once; users of a clone
consent to the rules the prototype already encodes.

The factory machinery (`proto` immutable, `make()`, `made()`, the
prototype-forward dance, `Unauthorized` error) is provided by the
shared `Prototype` base contract in `uniteum/proto`. A Bitsy contract
inherits it and overrides one virtual hook — `zzInit(bytes, uint256)`.
That is the entire mechanical change. The rest of this skill is about
the *non-mechanical* work: stripping things the prototype can't have
(access control, mutability, oracles, upgrade paths).

The input is a path to a Solidity contract file: `$ARGUMENTS`

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

## Step 0a: Already a Bitsy contract? (migration path)

If the input already hand-rolls the Bitsy factory machinery — that is,
the contract has all of:

- `address public immutable proto = address(this);` (or a domain-named
  equivalent like `HUB`/`NOTHING`/`MOB`)
- a `make(...)` factory function with an `address(this) == proto`
  forward branch
- a `made(...)` view predictor
- a `zzInit(...)` initializer with a `msg.sender != proto` check
- an `error Unauthorized();` declaration

then this is a **migration**, not a fresh conversion. The
prototype/access/mutability cleanup (Steps 4–7) was done when the
contract was first bitsified; only the factory boilerplate changes.

The mechanical migration steps:

1. **Inherit `Prototype`.** Add the import and update the contract
   header:

   ```solidity
   import {Prototype} from "proto/Prototype.sol";

   contract Foo is Prototype, /* other bases */ { ... }
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

Place the factory-facing methods (`zzInit`, plus any typed `make`/
`made`/`encode` wrappers you add) **at the end** of the contract,
after the original business logic. This keeps core logic front and
center, with the cloning machinery grouped together at the bottom —
matching the Etherscan read experience where users see business
functions first.

```
contract Foo is Prototype {
    // — state variables (no `proto` — that's inherited) —
    // — errors, events, modifiers —
    // — constructor (immutables and parent constructors only) —
    // — core business logic (unchanged) —
    // — factory: encode(), made(), make(), zzInit() —
}
```

## Step 1: Inherit `Prototype`

Add the import and inheritance:

```solidity
import {Prototype} from "proto/Prototype.sol";

contract Foo is Prototype, /* other bases */ { ... }
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

1. An `encode()` pure function that validates and `abi.encode`s the
   per-clone init args (everything except `variant`).
2. A typed `made(...)` that delegates to `this.made(encode(...), variant)`.
3. A typed `make(...)` that calls `encode()`, then `this.make(args, variant)`
   on the inherited bytes overload.

Example (cribbed from `Lepton`):

```solidity
function encode(address maker, string calldata name, string calldata symbol, uint8 decimals_, uint256 supply)
    public pure returns (bytes memory args)
{
    if (bytes(name).length == 0) revert Nameless();
    if (bytes(symbol).length == 0) revert Symbolless();
    if (supply == 0) revert Nothing();
    args = abi.encode(maker, name, symbol, decimals_, supply);
}

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
