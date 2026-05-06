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

The input is a path to a Solidity contract file: `$ARGUMENTS`

## Step 0: Read and understand

Read the target contract. Before making any changes, identify:

- **Constructor parameters** — these become `make()` / `zzInit()` args
  and salt inputs.
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

## Layout rule

Place the factory methods (`made`, `make`, `zzInit`) **at the end**
of the contract, after the original business logic. The proto
immutable goes at the top with other state declarations. This keeps
the contract's core logic front and center, with the cloning
machinery grouped together at the bottom — matching the Etherscan
read experience where users see business functions first.

```
contract Foo {
    // — immutables (including proto) —
    // — state variables —
    // — errors, events, modifiers —
    // — constructor —
    // — core business logic (unchanged) —
    // — factory: made(), make(), zzInit() —
}
```

## Step 1: Add the Clones import and self-referential immutable

Add the Clones library import. Use the version from the Uniteum
repos if available in the project's dependencies, otherwise use
OpenZeppelin's `@openzeppelin/contracts/proxy/Clones.sol`.

Add the self-referential immutable. Name it after the contract's
role. Convention from existing Bitsy contracts:

```solidity
// The prototype instance. On clones, this points back to the
// original deployment.
ContractName public immutable proto = address(this);
// or, if the contract has a domain-specific name:
// ISolid public immutable NOTHING = this;
// Liquid public immutable HUB = this;
// IMob public immutable MOB = this;
```

Use the typed self-reference (`ContractName`, not `address`) when
the contract calls its own functions on the prototype.

## Step 2: Convert the constructor to `zzInit()`

### 2a: Empty the constructor

Move initialization logic out of the constructor. The constructor
should only:
- Call parent constructors with fixed values
- Set immutables (these are baked into bytecode and shared by clones)

```solidity
constructor() ERC20("", "") {}
```

### 2b: Create `zzInit()`

Create a public initialization function with a prototype guard.
The naming convention is `zzInit` (two z's) — this sorts last on
Etherscan's function list, keeping it out of users' way.

```solidity
/// @notice Initializer called by the prototype on a freshly
///         deployed clone. Reverts if called by anyone else.
function zzInit(/* former constructor params */) public {
    if (msg.sender != proto) revert Unauthorized();
    // ... initialization logic from the old constructor ...
}
```

**Guard pattern options** (pick one):

- **`msg.sender` check** (preferred): `if (msg.sender != proto) revert Unauthorized();`
- **State check** (when the prototype can't call directly):
  `if (bytes(_symbol).length != 0) revert AlreadyInitialized();`

If the contract doesn't already define an `Unauthorized` error,
add one:

```solidity
error Unauthorized();
```

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

Set `_name` and `_symbol` in `zzInit()`, not in the constructor.

## The proto rule

Two invariants every Bitsy maker must satisfy:

1. **`make()` MUST return the same `home` address as `made()`** for
   the same parameters. They cannot disagree on where the clone lives.
2. **Clone addresses MUST be computed from the prototype** — both the
   `predictDeterministicAddress` call in `made()` and the
   `cloneDeterministic` call in `make()` use `proto` as the
   implementation and the deployer, never `address(this)`.

These invariants must hold no matter which instance the function is
called on. If `make()` and `made()` are callable on clones, they must
delegate to the prototype or otherwise return the same result the
prototype would. If that's impractical — for example because `make()`
depends on `msg.sender` and forwarding would break the identity — then
`make()` on a clone must revert. It must never silently deploy a
clone-of-clone or return an address that disagrees with `made()`.

## Step 3: Add `made()` — deterministic address prediction

Add a view function that computes the deterministic address for a
given set of parameters without deploying. It must use `proto` as
both the implementation and the deployer so the prediction is the
same whether `made()` is called on the prototype or any clone.
Always include a `variant` parameter — see
[Variant and vanity mining](#variant-and-vanity-mining) below.

```solidity
function made(/* parameters */, uint256 variant)
    public
    view
    returns (bool exists, address home, bytes32 salt)
{
    // Validate inputs
    // ...

    // Derive salt: keccak of args, XOR'd with the user-supplied variant.
    salt = keccak256(abi.encode(param1, param2, ...)) ^ bytes32(variant);

    // Predict the CREATE2 address — proto is BOTH the implementation
    // and the deployer, so the result is identical from any caller.
    home = Clones.predictDeterministicAddress(
        address(proto), salt, address(proto)
    );

    // Check if already deployed
    exists = home.code.length > 0;
}
```

**Salt design rules:**
- Include every parameter that makes this instance distinct.
- Use `abi.encode` (not `abi.encodePacked`) to avoid collisions.
- **Always XOR with `bytes32(variant)`** at the end. This lets users
  vanity-mine clone addresses with `saltminer` while keeping `args`
  constant — different variants with the same args yield different
  clones, and a clone's address is fully determined by `(args,
  variant)`.
- If the creator's identity should differentiate instances (like
  Lepton), include `msg.sender` / maker address in the salt.
- If instances should be globally unique by content (like Solid's
  name+symbol), omit the creator.

## Step 4: Add `make()` — idempotent factory

Add the factory function. It must be idempotent: calling it twice
with the same parameters returns the same address. And it must
satisfy the two invariants in [The proto rule](#the-proto-rule).

```solidity
function make(/* parameters */, uint256 variant)
    external
    returns (IContractName instance)
{
    // Required when make() can sensibly run on a clone: forward to
    // the prototype so address(this) in cloneDeterministic is proto.
    if (this != proto) {
        instance = proto.make(/* parameters */, variant);
        return instance;
    }

    (bool exists, address home, bytes32 salt) = made(/* parameters */, variant);
    instance = IContractName(home);
    if (!exists) {
        // proto is BOTH the implementation and the deployer — never
        // address(this). When make() runs on the prototype the two
        // are equal, but writing proto explicitly is the rule.
        Clones.cloneDeterministic(address(proto), salt, 0);
        ContractName(home).zzInit(/* parameters */);
    }
}
```

If `make()` cannot meaningfully run on a clone (for example because
its behavior depends on `msg.sender` and forwarding would lose that
identity), replace the forward with a revert:

```solidity
if (this != proto) revert Unauthorized();
```

Either way, `make()` and `made()` must never disagree on `home`.

### Variant and vanity mining

The `variant` parameter is what makes Bitsy clones compatible with
GPU-based vanity-address mining. Internally the salt is
`keccak(args) ^ variant`, so the contract receives the args (which
must be valid and consistent with whatever `zzInit` does) and a
freely chosen `uint256` that just steers the address.

The standard mining workflow uses `saltminer`:

```bash
saltminer \
  --deployer     <prototype address>    # the factory, not Nick
  --initcodehash <keccak of EIP-1167 stub keyed to prototype>
  --argshash     <keccak(abi.encode(args))>
  --mask         0xffff...0000           # bits the address must match
  --target       0xfeed...0000           # target value under the mask
```

`saltminer` varies the variant, computes the resulting clone
address, and exits when it finds one matching `(addr & mask) ==
target`. The variant is then committed as a deployment input and
passed verbatim to `make()` whenever the clone is deployed on a new
chain — every chain produces the same clone address because every
chain runs the same XOR over the same inputs.

For prototype contracts deployed via Nick rather than via a Bitsy
factory, the caller mines the CREATE2 salt directly — `variant`
applies only to clones produced through `make()`.

See [crucible/docs/deployment.md](../../../docs/deployment.md) for
how mined variants are committed alongside the rest of the
deployment artifacts and how `deploy.sh` consumes them.

## Step 5: Strip prototype-level access control

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
    if (msg.sender != address(proto)) {
        // Verify caller is a valid clone
        (, address expected,) = made(/* caller's params */);
        if (msg.sender != expected) revert Unauthorized();
    }
    _;
}
```

## Step 6: Strip prototype-level mutability

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

## Step 7: Strip upgrade mechanisms

Remove:
- UUPS, transparent proxy, beacon proxy patterns
- `selfdestruct` / `SELFDESTRUCT` opcode usage
- `delegatecall` to mutable targets
- Storage gaps (`__gap`)
- Initializable guards from OpenZeppelin's upgradeable contracts
  (replace with the simpler `zzInit` pattern)

## Step 8: Flag oracle dependencies

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

## Step 9: Verify

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
4. **Cloned**: Uses EIP-1167 minimal proxy via `Clones` library.
5. **Deterministic**: `make()` uses CREATE2 with content-derived salt.
   `made()` predicts the address. `make()` and `made()` agree on `home`
   from any caller, and clone addresses are computed from `proto` —
   see [The proto rule](#the-proto-rule).
6. **Direct**: Every factory operation is a single function call. No
   multi-step workflows on the prototype beyond standard ERC-20
   approvals.
7. **Composable**: Prototype exposes standard interfaces. Clones
   present standard interfaces (e.g. ERC-20) where applicable.
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
