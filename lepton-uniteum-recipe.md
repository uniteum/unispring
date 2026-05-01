# Recipe: mint a Uniteum token with an 8-leading-`f` address

End-to-end walkthrough for deploying a fixed-supply ERC-20 token via [Lepton](https://github.com/uniteum/lepton) on Sepolia, with a vanity address that begins with eight `f` hex characters (e.g. `0xffffffff...`). Salt mining is done with [saltminer](https://github.com/uniteum/saltminer).

Target token:

| Field  | Value        |
| ------ | ------------ |
| name   | `Uniteum`    |
| symbol | `1`          |
| supply | 1 000 000 (× 10¹⁸ wei, i.e. 18 decimals) |

## 0. Prerequisites

- **Foundry** (`cast`, `forge`) — <https://book.getfoundry.sh/getting-started/installation>
- **saltminer** built and working — see <https://github.com/uniteum/saltminer>, verify with `saltminer --list-devices`
- **A Sepolia account** with enough ETH for one transaction, imported into Foundry's keystore (`cast wallet import`) or available via a hardware wallet
- **A Sepolia RPC URL** (public endpoint or Alchemy/Infura), exported as `SEPOLIA_RPC_URL` or configured in `foundry.toml` under `[rpc_endpoints].sepolia`

Addresses used below:

```sh
# Lepton prototype factory on Sepolia (verified):
#   https://sepolia.etherscan.io/address/0x27a9ebac078e618f50b6ecd196a596cb684a3f46#code
export LEPTON=0x27a9ebac078e618f50b6ecd196a596cb684a3f46

# The account that will call Lepton.make. The ENTIRE supply mints to this address.
export MAKER=0xYourAddressHere
```

## 1. Compute `argsHash`

`Lepton.made` hashes `abi.encode(maker, name, symbol, supply)` and XORs the result with your salt. Precompute that hash off-chain so the miner has something fixed to work with:

```sh
export NAME="Uniteum"
export SYMBOL="1"
export SUPPLY=1000000000000000000000000   # 1_000_000 * 1e18

export ARGS_HASH=$(cast keccak $(cast abi-encode \
  "f(address,string,string,uint256)" \
  $MAKER "$NAME" "$SYMBOL" $SUPPLY))

echo "args_hash = $ARGS_HASH"
```

Anyone changing their `MAKER` will get a different `argsHash` and therefore a different mined salt and different target address — the binding is intentional.

## 2. Compute `initcodeHash`

Lepton clones tokens as EIP-1167 minimal proxies pointing at itself. `CREATE2` hashes the 55-byte proxy init code with the implementation address (= `LEPTON`) spliced in — **not** the Lepton factory's own deployment bytecode. Getting this wrong is the single most common mistake; see the "Gotcha" section of the saltminer README.

```sh
export INITCODE_HASH=$(cast keccak \
  0x3d602d80600a3d3981f3363d3d373d3d3d363d73${LEPTON#0x}5af43d82803e903d91602b57fd5bf3)

echo "initcode_hash = $INITCODE_HASH"
```

This is a constant for a given Lepton deployment — you only ever recompute it if Lepton itself is redeployed at a new address.

## 3. Mine the salt

Eight leading `f` hex characters = 32 bits set at the top of the address. Probability per attempt is `1 / 2^32 ≈ 1 / 4.3 × 10^9`. On a modest integrated GPU expect anywhere from a few minutes to ~an hour; on a discrete GPU it is seconds.

```sh
saltminer \
  --deployer      $LEPTON \
  --initcode-hash $INITCODE_HASH \
  --args-hash     $ARGS_HASH \
  --mask          0xffffffff00000000000000000000000000000000 \
  --match         0xffffffff00000000000000000000000000000000
```

Output on success:

```
salt = 0x0000000000000000000000000000000000000000000000000000000000000XXX
home = 0xffffffffXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

Save both values — `SALT` is what you'll pass to `make`, and `HOME` is the token address that will be deployed.

```sh
export SALT=0x0000000000000000000000000000000000000000000000000000000000000XXX
export HOME_ADDR=0xffffffffXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

### Sanity check before spending gas

Have Lepton itself predict the address for the mined salt. `made` is a free `view` call — no transaction needed:

```sh
cast call $LEPTON \
  "made(address,string,string,uint256,bytes32)(bool,address,bytes32)" \
  $MAKER "$NAME" "$SYMBOL" $SUPPLY $SALT \
  --rpc-url $SEPOLIA_RPC_URL
```

The second return value (`home`) **must** exactly equal `$HOME_ADDR`. If it doesn't, re-check `ARGS_HASH` (was `MAKER` correct?) and `INITCODE_HASH` (did you hash the EIP-1167 proxy, not the factory bytecode?). The first return value (`deployed`) must be `false` — otherwise someone else already claimed this exact token and you need a different salt.

## 4. Deploy the token

One transaction calling `make`. The caller (`$MAKER`) receives the entire supply atomically.

```sh
cast send $LEPTON \
  "make(string,string,uint256,bytes32)" \
  "$NAME" "$SYMBOL" $SUPPLY $SALT \
  --rpc-url $SEPOLIA_RPC_URL \
  --account <your-foundry-account>
```

(Replace `<your-foundry-account>` with the name you used in `cast wallet import`, or use `--private-key` / `--ledger` / `--trezor` as appropriate.)

## 5. Verify on-chain

```sh
# Token is deployed and owned by maker
cast call $LEPTON \
  "made(address,string,string,uint256,bytes32)(bool,address,bytes32)" \
  $MAKER "$NAME" "$SYMBOL" $SUPPLY $SALT \
  --rpc-url $SEPOLIA_RPC_URL
# → deployed=true, home=$HOME_ADDR

# Maker holds the entire supply
cast call $HOME_ADDR "balanceOf(address)(uint256)" $MAKER --rpc-url $SEPOLIA_RPC_URL
# → 1000000000000000000000000

# Standard ERC-20 metadata
cast call $HOME_ADDR "name()(string)"   --rpc-url $SEPOLIA_RPC_URL   # → "Uniteum"
cast call $HOME_ADDR "symbol()(string)" --rpc-url $SEPOLIA_RPC_URL   # → "1"
cast call $HOME_ADDR "totalSupply()(uint256)" --rpc-url $SEPOLIA_RPC_URL
```

View in a browser: `https://sepolia.etherscan.io/token/<HOME_ADDR>`.

## Notes

- **The supply is fixed.** Lepton tokens cannot be minted after creation — `make` is a one-shot that transfers the whole supply to the caller. If you need more, mint a differently-named token.
- **The address is deterministic.** Calling `make` twice with the same `(maker, name, symbol, supply, salt)` returns the existing token, not a new one. The `salt` is what distinguishes otherwise-identical deployments by the same maker.
- **Changing any field invalidates the mined salt.** Maker, name, symbol, supply — all four bind into `argsHash`. Even flipping a single character in `name` means you have to remine.
- **Mining and deploying can happen on different machines.** The miner only needs `deployer`, `initcode_hash`, `args_hash`, and the mask/match. The deploying wallet only needs the salt value. No secrets cross between them.
