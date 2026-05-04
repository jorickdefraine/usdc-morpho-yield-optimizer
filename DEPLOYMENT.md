# Secure Deployment Process — UMYOVault

## Security model recap

The vault enforces **dual-key separation**: the owner approves vault targets; the rebalancer executes fund movements. Draining funds requires compromising **both** keys simultaneously. This only holds if the two roles are different addresses — the deployment script now enforces this at the contract call level.

---

## Prerequisites

| Item | Requirement |
|------|-------------|
| Owner | A multisig (Safe, Gnosis) with ≥ 2-of-N signers. Never an EOA. |
| Rebalancer | A hot-wallet EOA controlled by the keeper bot. Must differ from owner. |
| Deployer | Any funded EOA. Temporary admin only — discarded after ownership transfer. |
| Morpho vault address | Must be pre-vetted: correct underlying asset, audited, sufficient TVL. |

---

## Step 1 — Pre-deployment checklist

- [ ] Confirm `VAULT_OWNER` is a multisig address, not the same as `REBALANCER`.
- [ ] Confirm `MORPHO_VAULT` underlying asset matches `USDC_ADDRESS`.
- [ ] Confirm `MORPHO_VAULT` is the Morpho vault you intend as the initial target (can be changed via `rebalance()` later).
- [ ] Deploy on a testnet first with the same parameters; run the full test suite against it.
- [ ] Ensure the deployer EOA has enough ETH for gas (Base mainnet: ~0.01 ETH is sufficient).

---

## Step 2 — Set environment variables

```bash
export CHAIN_ID=8453
export RPC_URL=https://mainnet.base.org
export PRIVATE_KEY=0x<deployer-private-key>      # temporary, discard after step 4
export USDC_ADDRESS=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
export MORPHO_VAULT=0x<initial-morpho-vault>
export VAULT_OWNER=0x<multisig-address>           # NOT the deployer
export REBALANCER=0x<keeper-hot-wallet>           # NOT the same as VAULT_OWNER
```

**Never commit `PRIVATE_KEY` to version control.**

---

## Step 3 — Deploy (Phase 1)

```bash
forge script scripts/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  -vvv
```

The script:
1. Deploys `UMYOVault` with the deployer as the **temporary** owner.
2. Calls `approveVault`, `setMorphoVault`, `setRebalancer` while the deployer is owner.
3. Calls `vault.transferOwnership(VAULT_OWNER)` — this sets `pendingOwner` but does **not** transfer ownership yet (`Ownable2Step`).

After this step, `vault.owner()` is still the deployer and `vault.pendingOwner()` is the multisig.

---

## Step 4 — Complete ownership transfer (Phase 2)

The multisig at `VAULT_OWNER` must call `acceptOwnership()` to finalize the transfer.

**Using Safe UI:**
1. Go to [app.safe.global](https://app.safe.global) → your multisig.
2. New transaction → Contract interaction → paste vault address.
3. ABI method: `acceptOwnership()` (no arguments).
4. Collect required signatures and execute.

**Using cast (for scripted multisigs):**
```bash
cast send $VAULT_ADDRESS "acceptOwnership()" \
  --rpc-url $RPC_URL \
  --private-key $MULTISIG_SIGNER_KEY
```

**Verify the transfer succeeded:**
```bash
cast call $VAULT_ADDRESS "owner()(address)" --rpc-url $RPC_URL
# must return the multisig address

cast call $VAULT_ADDRESS "pendingOwner()(address)" --rpc-url $RPC_URL
# must return 0x0000...0000
```

After this step, the deployer key has **zero admin capability**. Rotate or discard it.

---

## Step 5 — Post-deployment verification

Run all checks before announcing the vault to users:

```bash
# 1. Confirm configuration
cast call $VAULT_ADDRESS "owner()(address)" --rpc-url $RPC_URL
cast call $VAULT_ADDRESS "rebalancer()(address)" --rpc-url $RPC_URL
cast call $VAULT_ADDRESS "morphoVault()(address)" --rpc-url $RPC_URL
cast call $VAULT_ADDRESS "asset()(address)" --rpc-url $RPC_URL

# 2. Confirm vault whitelist
cast call $VAULT_ADDRESS "approvedVaults(address)(bool)" $MORPHO_VAULT --rpc-url $RPC_URL
# must return true

# 3. Confirm the Morpho vault's underlying matches USDC
cast call $MORPHO_VAULT "asset()(address)" --rpc-url $RPC_URL
# must match USDC_ADDRESS

# 4. Confirm no funds are deployed yet (totalAssets = 0)
cast call $VAULT_ADDRESS "totalAssets()(uint256)" --rpc-url $RPC_URL
```

---

## Step 6 — Initial deposit and deployment

After the vault is live and verified, the keeper deploys the first batch of deposits:

```bash
# Users deposit via vault.deposit() or vault.mint()
# Keeper then deploys idle USDC to Morpho:
cast send $VAULT_ADDRESS "deployToMorpho(uint256)" 0 \
  --rpc-url $RPC_URL \
  --private-key $REBALANCER_KEY
```

For production, use the `rebalancer.js` keeper script which computes a proper `minSharesOut` value automatically.

---

## Ongoing operations

### Rebalancing to a new Morpho vault

Before the keeper can rebalance to a new vault, the **owner (multisig) must whitelist it first**:

```bash
# Multisig transaction:
vault.approveVault(newMorphoVaultAddress)
```

Only after this on-chain whitelist approval can the keeper call `rebalance()`. A compromised keeper key cannot route funds to an unapproved address.

### Emergency: pause deposits

```bash
# Multisig transaction:
vault.pause()
# Withdrawals remain open. Deposits and mints are blocked.
```

### Emergency: recall all funds from Morpho

Either the multisig or the rebalancer can call this:

```bash
cast send $VAULT_ADDRESS "recallFromMorpho()" \
  --rpc-url $RPC_URL \
  --private-key $REBALANCER_KEY   # or multisig signer
```

Funds return to the vault as idle USDC. Users can still withdraw. Redeploy with `deployToMorpho()` when safe.

### Rotating the rebalancer key

If the keeper hot wallet is compromised:

```bash
# Multisig transaction:
vault.setRebalancer(newKeeperAddress)
```

The old key immediately loses all rebalancer capability.

### Rotating the owner (multisig upgrade)

```bash
# Multisig transaction (old multisig):
vault.transferOwnership(newMultisigAddress)

# New multisig transaction:
vault.acceptOwnership()
```

Ownership does not transfer until `acceptOwnership()` is called — no risk of accidental lock-out.

---

## Key management rules

| Key | Storage | Rotation trigger |
|-----|---------|-----------------|
| Deployer EOA | Discard after `acceptOwnership()` completes | N/A |
| Owner multisig | Hardware signers, geographically distributed | Signer compromise or policy change |
| Rebalancer EOA | HSM or secrets manager (e.g. AWS KMS, HashiCorp Vault) | Any suspected exposure |

**Never** store the rebalancer private key in plaintext on the server running the keeper. Use a KMS-backed signer.

---

## Rebalance cooldown recommendation

Set a minimum cooldown to limit the blast radius of a compromised rebalancer key:

```bash
# Multisig transaction — 1 hour minimum between rebalances:
vault.setRebalanceCooldown(3600)
```

A compromised rebalancer can only cause one rebalance per hour, limiting gas-griefing and repeated-slippage attacks before the owner can rotate the key.
