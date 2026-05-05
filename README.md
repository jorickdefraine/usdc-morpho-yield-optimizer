# USDC Morpho Yield Optimizer

ERC-4626 vault that automatically routes USDC into the highest-yielding whitelisted Morpho vault on Base. An off-chain keeper monitors APY via the Morpho GraphQL API and triggers rebalances when a better opportunity clears a configurable threshold.

---

## How it works

```
Users ──deposit USDC──► UMYOVault (vUMYO shares)
                              │
                              └──► active Morpho ERC-4626 vault (best APY)
                                        ▲
                         Keeper ────rebalance() every 12h
```

1. **Users** deposit USDC and receive `vUMYO` shares. Withdrawals pull from Morpho automatically if needed.
2. **Keeper** runs every 12 hours, fetches APYs from the Morpho API, and calls `rebalance(newVault)` if a better vault clears the `MIN_APY_IMPROVEMENT` threshold.
3. **Owner** (multisig) manages the vault whitelist, can pause the vault, emergency-withdraw all funds, and claim Morpho reward tokens.

Rebalancing is atomic: recall all shares from the old vault → deposit everything into the new vault, in one transaction.

---

## Roles

| Role | Capabilities |
|---|---|
| **Owner** (multisig) | `allowVault`, `pause`, `emergencyWithdraw`, `claimRewards`, `sweepRewards` |
| **Keeper** (EOA) | `rebalance` — also callable by owner as fallback |

---

## Deployment

### 1. Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js ≥ 18

### 2. Install & build

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge build
forge inspect UMYOVault abi > scripts/UMYOVaultABI.json
```

### 3. Configure environment

```bash
cp .env.example .env
# Fill in: PRIVATE_KEY, USDC_ADDRESS, MORPHO_VAULT, VAULT_OWNER, KEEPER
```

### 4. Deploy

```bash
forge script scripts/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  -vvv
```

The script deploys the vault, whitelists the initial Morpho vault, and initiates ownership transfer to the multisig.

### 5. Accept ownership (multisig)

The multisig at `VAULT_OWNER` must call `acceptOwnership()` to finalize the two-step transfer.

### 6. Deploy idle USDC

Once users have deposited, the keeper calls `rebalance(morphoVaultAddress)` to push idle USDC into Morpho.

---

## Keeper

```bash
npm install
node scripts/rebalancer.js
```

Required env vars: `CHAIN_ID`, `RPC_URL`, `CONTRACT_ADDRESS`, `PRIVATE_KEY`.  
Optional: `MIN_APY_IMPROVEMENT` (default: `0.5`, meaning 0.5% APY delta).

The keeper is also configured to run automatically via GitHub Actions every 12 hours (see [`.github/workflows/launch_rebalancer.yml`](.github/workflows/launch_rebalancer.yml)).

---

## Tests

```bash
forge test -v          # summary
forge test -vvv        # traces on failures
```
