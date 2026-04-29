# USDC Morpho Yield Optimizer

An ERC-4626 vault that routes USDC into the highest-yielding whitelisted Morpho vault on Base. An off-chain keeper monitors APY via the Morpho GraphQL API and triggers atomic rebalances when a better opportunity clears a configurable threshold.

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                       UMYOVault                         │
│  ERC-4626 (OZ 5.x) · Ownable · ReentrancyGuard         │
│                                                         │
│  Users  ──deposit/withdraw──►  vault shares (vUMYO)    │
│                                                         │
│  Keeper ──deployToMorpho()──►  active Morpho ERC-4626  │
│         ──rebalance()       ►  (switch atomically)     │
│                                                         │
│  Owner  ──recallFromMorpho()►  idle USDC in vault      │
└─────────────────────────────────────────────────────────┘
```

**Single-strategy:** all USDC is deployed into one Morpho vault at a time. Rebalancing is fully atomic — withdraw from the old vault, switch the pointer, deposit into the new vault, all in one transaction.

**Dual access roles:**
- **Owner** (multisig recommended): vault configuration, emergency recall, rebalancer assignment.
- **Rebalancer** (keeper EOA): time-sensitive operations — `deployToMorpho()`, `rebalance()`. The owner can always act as rebalancer to prevent lockout if the keeper key is lost.

---

## Security Properties

| Property | Implementation |
|---|---|
| Reentrancy | `nonReentrant` on all user-facing state-changing functions |
| USDC approval | `SafeERC20.forceApprove` with exact per-call amounts (no infinite approvals) |
| Inflation attack | OZ virtual shares (+1/+1) protection in ERC-4626 base |
| Slippage on recall | `minAssetsReceived` parameter in `rebalance()` |
| `maxWithdraw` / `maxRedeem` | EIP-4626 compliant — capped by available Morpho liquidity |
| `redeem()` override | Both `withdraw()` and `redeem()` trigger Morpho recall — omitting the `redeem` override was a critical bug in earlier drafts |

---

## Repository Layout

```
contracts/
  UMYOVault.sol        # Core vault (ERC-4626)
  FakeMorpho.sol       # Test double: simulates yield/loss
  FakeUSDC.sol         # Mintable ERC-20 for tests

scripts/
  Deploy.s.sol         # Foundry deployment script
  rebalancer.js        # Off-chain keeper (Node.js / ethers.js v6)
  UMYOVaultABI.json    # Generated: forge inspect UMYOVault abi

test/
  UMYOVault.t.sol      # 30 tests: unit, fuzz, invariant
```

---

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js ≥ 18 (for the keeper script)

### Build

```bash
forge install OpenZeppelin/openzeppelin-contracts
forge build
```

### Test

```bash
forge test -v          # summary
forge test -vvv        # with traces on failures
forge test --match-test testFuzz  # fuzz tests only
```

All 30 tests pass (26 unit, 2 fuzz, 2 invariant).

### Regenerate ABI

```bash
forge inspect UMYOVault abi > scripts/UMYOVaultABI.json
```

---

## Deployment

Copy `.env.example` to `.env` and fill in all values.

```bash
forge script scripts/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  -vvv
```

The script:
1. Deploys `UMYOVault` with `USDC_ADDRESS` as the underlying asset and `VAULT_OWNER` as the initial owner.
2. Calls `setMorphoVault(MORPHO_VAULT)` to configure the initial target.
3. Calls `setRebalancer(REBALANCER)` to authorize the keeper.

After deployment, call `deployToMorpho()` (as owner or rebalancer) once users have deposited to push idle USDC into Morpho.

---

## Keeper Script

The keeper (`scripts/rebalancer.js`) runs on a schedule (GitHub Actions, cron, etc.):

1. Fetches all whitelisted USDC vaults on the configured chain from the Morpho GraphQL API.
2. Compares the best available APY against the current vault's APY.
3. If the improvement exceeds `MIN_APY_IMPROVEMENT` (default 0.5%), computes `minAssetsReceived` with `SLIPPAGE_BPS` tolerance and calls `vault.rebalance(newVault, minAssetsReceived)`.

```bash
npm install
node scripts/rebalancer.js
```

### GitHub Actions example

```yaml
on:
  schedule:
    - cron: '0 * * * *'   # hourly
jobs:
  rebalance:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '20' }
      - run: npm ci
      - run: node scripts/rebalancer.js
        env:
          CHAIN_ID: ${{ vars.CHAIN_ID }}
          RPC_URL: ${{ secrets.RPC_URL }}
          CONTRACT_ADDRESS: ${{ vars.CONTRACT_ADDRESS }}
          PRIVATE_KEY: ${{ secrets.REBALANCER_PRIVATE_KEY }}
          MIN_APY_IMPROVEMENT: '0.5'
          SLIPPAGE_BPS: '50'
```

---

## Key Design Decisions

**Why single-strategy?** Multi-strategy vaults (e.g., Morpho's MetaMorpho) add significant complexity around allocation, partial rebalances, and per-market risk. A single active position keeps accounting simple and avoids the class of bugs that come from partial-withdrawal ordering across multiple markets.

**Why `forceApprove` instead of `approve`?** USDC uses a non-standard ERC-20 that requires the allowance to be set to zero before it can be raised to a non-zero value. `SafeERC20.forceApprove` handles this automatically. Setting exact-amount approvals per call (rather than `type(uint256).max` once) also limits damage from a hypothetical approval exploit.

**Why override both `withdraw` and `redeem`?** EIP-4626 exposes two redemption paths. If only `withdraw` is overridden, a user calling `redeem` bypasses the Morpho recall logic — the base implementation transfers from the vault's local balance, which may be zero, causing a silent revert or incorrect behaviour.

**Why `convertToAssets` in `totalAssets`?** `previewRedeem` applies floor rounding that favours the vault and can return slightly less than the true share value. `convertToAssets` is the right semantic here: it reports the asset equivalent of a given share count without an intentional rounding adjustment.

**`maxRedeem` rounding edge case:** The naive implementation `min(balanceOf(owner), convertToShares(availableLiquidity))` has a subtle bug: when the exchange rate is above 1:1 and all assets are already local (e.g., after a recall), `convertToShares(liquidity)` rounds down to `totalSupply - 1`, which incorrectly blocks a full redemption. The fix: if `availableLiquidity >= convertToAssets(userShares)`, return the user's full share balance directly.
