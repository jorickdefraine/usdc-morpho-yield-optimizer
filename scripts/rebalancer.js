require('dotenv').config();

const { ethers } = require('ethers');
const axios = require('axios');
const UMYOVaultABI = require('./UMYOVaultABI.json');

// ─── Configuration ─────────────────────────────────────────────────────────

const REQUIRED_ENV = ['CHAIN_ID', 'RPC_URL', 'CONTRACT_ADDRESS', 'PRIVATE_KEY'];
for (const key of REQUIRED_ENV) {
  if (!process.env[key]) throw new Error(`Missing required env var: ${key}`);
}

const CHAIN_ID            = parseInt(process.env.CHAIN_ID, 10);
const RPC_URL             = process.env.RPC_URL;
const VAULT_ADDRESS       = process.env.CONTRACT_ADDRESS;
const PRIVATE_KEY         = process.env.PRIVATE_KEY;
const MORPHO_API_URL      = 'https://api.morpho.org/graphql';

// Only rebalance if the best vault offers at least this much more APY (absolute, e.g. 0.5 = 0.5%)
const MIN_APY_IMPROVEMENT = 0.1 //parseFloat(process.env.MIN_APY_IMPROVEMENT ?? '0.5');

// Minimal ABI for a Morpho ERC4626 vault (read-only)
const MORPHO_VAULT_ABI = [
  'function asset() view returns (address)',
];

// ─── Morpho API ─────────────────────────────────────────────────────────────

async function getVaultsSortedByApy() {
  const query = `
    query {
      vaults(
        where: {
          chainId_in: [${CHAIN_ID}],
          whitelisted: true,
          assetSymbol_in: ["USDC"],
          totalAssetsUsd_gte: 1000000
        }
      ) {
        items {
          address
          symbol
          name
          state {
            avgNetApyExcludingRewards(lookback: ONE_DAY)
            avgNetApy(lookback: ONE_DAY)
          }
        }
      }
    }
  `;

  const { data } = await axios.post(
    MORPHO_API_URL,
    { query },
    { headers: { 'Content-Type': 'application/json' }, timeout: 10_000 }
  );

  if (data.errors?.length) {
    throw new Error(`Morpho API error: ${data.errors.map(e => e.message).join(', ')}`);
  }

  const vaults = data.data.vaults.items.filter(
    v => v.state.avgNetApy !== undefined && v.state.avgNetApy !== null
  );

  if (vaults.length === 0) throw new Error('No valid Morpho vaults found');

  return vaults.sort((a, b) => b.state.avgNetApy - a.state.avgNetApy);
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function optimizeVault() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer   = new ethers.Wallet(PRIVATE_KEY, provider);
  const vault    = new ethers.Contract(VAULT_ADDRESS, UMYOVaultABI, signer);

  // ── Step 1: current state ──────────────────────────────────────────────────
  const currentMarket = await vault.morphoVault();
  const isMarketSet   = currentMarket !== ethers.ZeroAddress;
  console.log(`Vault:          ${VAULT_ADDRESS}`);
  console.log(`Current market: ${isMarketSet ? currentMarket : '(none)'}`);

  // ── Step 2: find best available vault via Morpho API ──────────────────────
  const sortedVaults = await getVaultsSortedByApy();
  const bestVault    = sortedVaults[0];
  console.log(`Best vault:     ${bestVault.address} — ${bestVault.name}`);
  console.log(`Best APY:       ${(bestVault.state.avgNetApy * 100).toFixed(2)}%`);

  // ── Step 3: check if improvement justifies rebalance ──────────────────────
  if (isMarketSet && currentMarket.toLowerCase() === bestVault.address.toLowerCase()) {
    console.log('Already using the best vault. No action needed.');
    return;
  }

  if (isMarketSet) {
    const currentVaultData = sortedVaults.find(
      v => v.address.toLowerCase() === currentMarket.toLowerCase()
    );
    if (currentVaultData) {
      const currentApy  = currentVaultData.state.avgNetApy;
      const improvement = (bestVault.state.avgNetApy - currentApy) * 100;
      console.log(`Current APY:    ${(currentApy * 100).toFixed(2)}%`);
      console.log(`APY delta:      +${improvement.toFixed(2)}%`);
      if (improvement < MIN_APY_IMPROVEMENT) {
        console.log(`Improvement (${improvement.toFixed(2)}%) below threshold (${MIN_APY_IMPROVEMENT}%). Skipping.`);
        return;
      }
    }
  }

  // ── Step 4: on-chain safety checks ────────────────────────────────────────
  // Cross-check the API address against the on-chain whitelist.
  // A compromised/MITM'd API cannot route funds to an arbitrary contract —
  // the owner must explicitly call allowMarket() first.
  const isAllowed = await vault.allowedVaults(bestVault.address);
  if (!isAllowed) {
    throw new Error(
      `Vault ${bestVault.address} is not whitelisted on-chain. ` +
      `The owner must call allowVault(${bestVault.address}, true) first. Aborting.`
    );
  }

  // Verify underlying asset matches (defence against malicious vault in API).
  const newMorpho     = new ethers.Contract(bestVault.address, MORPHO_VAULT_ABI, provider);
  const vaultAsset    = await vault.asset();
  const newVaultAsset = await newMorpho.asset();
  if (newVaultAsset.toLowerCase() !== vaultAsset.toLowerCase()) {
    throw new Error(
      `Asset mismatch: vault uses ${vaultAsset}, but ${bestVault.address} uses ${newVaultAsset}. Aborting.`
    );
  }

  // ── Step 5: rebalance ─────────────────────────────────────────────────────
  console.log(`\nRebalancing → ${bestVault.name} (${bestVault.address})...`);
  const tx      = await vault.rebalance(bestVault.address);
  const receipt = await tx.wait();
  console.log(`Done. tx: ${receipt.hash}`);

  // Extract Rebalanced event for logging
  const rebalancedEvent = receipt.logs
    .map(log => { try { return vault.interface.parseLog(log); } catch { return null; } })
    .find(e => e?.name === 'Rebalanced');

  if (rebalancedEvent) {
    const { assetsDeployed } = rebalancedEvent.args;
    console.log(`Deployed: ${ethers.formatUnits(assetsDeployed, 6)} USDC`);
  }
}

optimizeVault().catch(err => {
  console.error('Rebalancer error:', err.message ?? err);
  process.exit(1);
});
