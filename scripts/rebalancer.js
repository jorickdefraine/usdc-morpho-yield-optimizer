require('dotenv').config();

const { ethers } = require('ethers');
const axios = require('axios');
const UMYOVaultABI = require('./UMYOVaultABI.json');

// ─── Configuration ─────────────────────────────────────────────────────────

const CHAIN_ID              = parseInt(process.env.CHAIN_ID, 10);
const RPC_URL               = process.env.RPC_URL;
const VAULT_ADDRESS         = process.env.CONTRACT_ADDRESS;
const PRIVATE_KEY           = process.env.PRIVATE_KEY;
const MORPHO_API_URL        = 'https://api.morpho.org/graphql';

// Only rebalance if the best vault offers at least this much more APY (absolute, e.g. 0.5 = 0.5%)
const MIN_APY_IMPROVEMENT   = parseFloat(process.env.MIN_APY_IMPROVEMENT ?? '0.5');

// Slippage tolerance on the recall AND deploy steps (basis points, e.g. 50 = 0.5%)
const SLIPPAGE_BPS          = parseInt(process.env.SLIPPAGE_BPS ?? '50', 10);

// Minimal ABI for the Morpho ERC4626 vault (read-only calls)
const MORPHO_VAULT_ABI = [
  'function asset() view returns (address)',
  'function maxWithdraw(address owner) view returns (uint256)',
  'function previewDeposit(uint256 assets) view returns (uint256)',
  'function balanceOf(address account) view returns (uint256)',
];

// Minimal ABI for the ERC20 underlying (idle balance check)
const ERC20_ABI = [
  'function balanceOf(address account) view returns (uint256)',
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
          dailyApys { netApy }
        }
      }
    }
  `;

  const { data } = await axios.post(
    MORPHO_API_URL,
    { query },
    { headers: { 'Content-Type': 'application/json' } }
  );

  const vaults = data.data.vaults.items.filter(
    v => v.dailyApys?.netApy !== undefined && v.dailyApys.netApy !== null
  );

  if (vaults.length === 0) throw new Error('No valid Morpho vaults found');

  return vaults.sort((a, b) => b.dailyApys.netApy - a.dailyApys.netApy);
}

// ─── Current vault APY ───────────────────────────────────────────────────────

async function getCurrentVaultApy(currentVaultAddress, allVaults) {
  const match = allVaults.find(
    v => v.address.toLowerCase() === currentVaultAddress.toLowerCase()
  );
  return match ? match.dailyApys.netApy : null;
}

// ─── Main ────────────────────────────────────────────────────────────────────

async function optimizeVault() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer   = new ethers.Wallet(PRIVATE_KEY, provider);
  const vault    = new ethers.Contract(VAULT_ADDRESS, UMYOVaultABI, signer);

  // ── Step 1: current state ──────────────────────────────────────────────────
  const currentVaultAddress = await vault.morphoVault();
  const isVaultSet = currentVaultAddress !== ethers.ZeroAddress;
  console.log(`Vault:         ${VAULT_ADDRESS}`);
  console.log(`Current Morpho: ${isVaultSet ? currentVaultAddress : '(none)'}`);

  // ── Step 2: find best available vault ─────────────────────────────────────
  const sortedVaults = await getVaultsSortedByApy();
  const bestVault    = sortedVaults[0];
  console.log(`Best vault:    ${bestVault.address} — ${bestVault.name}`);
  console.log(`Best APY:      ${(bestVault.dailyApys.netApy * 100).toFixed(2)}%`);

  // ── Step 3: check if improvement justifies rebalance ──────────────────────
  if (isVaultSet && currentVaultAddress.toLowerCase() === bestVault.address.toLowerCase()) {
    console.log('Already using the best vault. No action needed.');
    return;
  }

  if (isVaultSet) {
    const currentApy = await getCurrentVaultApy(currentVaultAddress, sortedVaults);
    if (currentApy !== null) {
      const improvement = (bestVault.dailyApys.netApy - currentApy) * 100;
      console.log(`Current APY:   ${(currentApy * 100).toFixed(2)}%`);
      console.log(`APY delta:     +${improvement.toFixed(2)}%`);
      if (improvement < MIN_APY_IMPROVEMENT) {
        console.log(`Improvement (${improvement.toFixed(2)}%) below threshold (${MIN_APY_IMPROVEMENT}%). Skipping.`);
        return;
      }
    }
  }

  // ── Step 4: on-chain safety checks ────────────────────────────────────────
  // Cross-check the API-returned address against the on-chain approved list.
  // This prevents a compromised or MITM'd API response from directing funds
  // to an arbitrary contract — the owner must explicitly whitelist the vault.
  const isApproved = await vault.approvedVaults(bestVault.address);
  if (!isApproved) {
    throw new Error(
      `Vault ${bestVault.address} is not in the on-chain approved list. ` +
      `The owner must call approveVault(${bestVault.address}) first. Aborting.`
    );
  }

  // Verify underlying asset matches to guard against a malicious vault slipping
  // through the API with a different token.
  const newMorpho   = new ethers.Contract(bestVault.address, MORPHO_VAULT_ABI, provider);
  const vaultAsset  = await vault.asset();
  const newVaultAsset = await newMorpho.asset();
  if (newVaultAsset.toLowerCase() !== vaultAsset.toLowerCase()) {
    throw new Error(
      `Asset mismatch: vault uses ${vaultAsset}, but ${bestVault.address} uses ${newVaultAsset}. Aborting.`
    );
  }

  // ── Step 5: compute slippage floors ───────────────────────────────────────
  let minAssetsReceived = 0n;
  let maxWithdraw = 0n;

  if (isVaultSet) {
    const currentMorpho = new ethers.Contract(currentVaultAddress, MORPHO_VAULT_ABI, provider);
    maxWithdraw = await currentMorpho.maxWithdraw(VAULT_ADDRESS);
    minAssetsReceived = maxWithdraw * BigInt(10_000 - SLIPPAGE_BPS) / 10_000n;
    console.log(`Max withdraw:  ${ethers.formatUnits(maxWithdraw, 6)} USDC`);
    console.log(`Min accepted:  ${ethers.formatUnits(minAssetsReceived, 6)} USDC`);
  }

  // Compute minSharesOut for the deploy step: query how many shares the new vault
  // would give for the total USDC to be deployed (recalled + idle), then apply
  // slippage tolerance.
  const underlying  = new ethers.Contract(vaultAsset, ERC20_ABI, provider);
  const idleAssets  = await underlying.balanceOf(VAULT_ADDRESS);
  const totalToDeploy = maxWithdraw + idleAssets;
  let minSharesOut  = 0n;
  if (totalToDeploy > 0n) {
    const expectedShares = await newMorpho.previewDeposit(totalToDeploy);
    minSharesOut = expectedShares * BigInt(10_000 - SLIPPAGE_BPS) / 10_000n;
    console.log(`Expected shares: ${expectedShares.toString()}`);
    console.log(`Min shares out:  ${minSharesOut.toString()}`);
  }

  // ── Step 6: rebalance (single atomic transaction) ─────────────────────────
  console.log(`\nRebalancing → ${bestVault.name} (${bestVault.address})...`);
  const tx = await vault.rebalance(bestVault.address, minAssetsReceived, minSharesOut);
  const receipt = await tx.wait();
  console.log(`Done. tx: ${receipt.hash}`);

  // Extract Rebalanced event for logging
  const rebalancedEvent = receipt.logs
    .map(log => { try { return vault.interface.parseLog(log); } catch { return null; } })
    .find(e => e?.name === 'Rebalanced');

  if (rebalancedEvent) {
    const { assetsWithdrawn, assetsDeployed } = rebalancedEvent.args;
    console.log(`Withdrawn:     ${ethers.formatUnits(assetsWithdrawn, 6)} USDC`);
    console.log(`Deployed:      ${ethers.formatUnits(assetsDeployed, 6)} USDC`);
  }
}

optimizeVault().catch(err => {
  console.error('Rebalancer error:', err.message ?? err);
  process.exit(1);
});
