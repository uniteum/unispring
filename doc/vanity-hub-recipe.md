# Vanity Hub Token Recipe

**Prerequisite:** The 4 prototypes from `.env` are deployed: `NeutrinoMaker`, `UnispringProto`, `ICoinage` (Lepton), `Neutrino`.

## Address derivation chain

```
leptonSalt  ──┐
               ▼
create2Salt = keccak256(maker, name, symbol, supply) ^ leptonSalt
hubAddress  = Clones.predictDeterministicAddress(LEPTON, create2Salt, LEPTON)
```

The `maker` address is fixed for a given tick range — it's the NeutrinoMaker clone for `(Neutrino, tickLower, tickUpper)`.

## 1. Fix your parameters

```
name="Hub"
symbol="HUB"
supply=1000000e18
tickLower=-133090
tickUpper=0
```

## 2. Compute the three saltminer inputs

All three values are deterministic and can be computed off-chain with `cast`.

**deployer** — the Lepton prototype (it calls `Clones.cloneDeterministic` on itself):

```bash
deployer=$ICoinage    # from .env
```

**initcode-hash** — the EIP-1167 minimal proxy init code keyed to the Lepton implementation:

```bash
initcode_hash=$(cast keccak "0x3d602d80600a3d3981f3363d3d373d3d3d363d73${ICoinage#0x}5af43d82803e903d91602b57fd5bf3")
```

**args-hash** — `keccak256(abi.encode(maker, name, symbol, supply))`. The `maker` is the NeutrinoMaker clone for this tick range:

```bash
# Compute the maker clone address
maker=$(cast call $NeutrinoMaker "made(address,int24,int24)(bool,address,bytes32)" \
  $Neutrino $tickLower $tickUpper | sed -n '2p')

# Compute argsHash
args_hash=$(cast keccak $(cast abi-encode "f(address,string,string,uint256)" \
  $maker "$name" "$symbol" $supply))
```

## 3. Mine the salt with saltminer

```bash
saltminer \
  --deployer      $deployer \
  --initcode-hash $initcode_hash \
  --args-hash     $args_hash \
  --mask          0xffff000000000000000000000000000000000001 \
  --match         0xffff000000000000000000000000000000000001 \
  --min 0 --max 0xffffffffffffffff
```

Adjust `--mask` and `--match` to your vanity pattern. The example above requires a `0xffff` prefix and a trailing `1` nibble.

The output is:

```
salt = 0x<64-hex-chars>
home = 0x<hub-address>
```

The `salt` value is your `leptonSalt`. Only the low 8 bytes vary; the upper 24 bytes equal the corresponding bytes of `args_hash`.

## 4. Deploy

Pass the full 32-byte salt to the contract:

```bash
cast send $Neutrino "make(string,string,uint256,int24,int24,bytes32)" \
  "$name" "$symbol" $supply $tickLower $tickUpper $salt
```

The hub token lands at the vanity address.
