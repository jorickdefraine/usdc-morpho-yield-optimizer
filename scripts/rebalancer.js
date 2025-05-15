require('dotenv').config(); // Load environment variables from .env file

const { JsonRpcProvider } = require('ethers/providers');
const { ethers } = require('ethers');
const axios = require('axios');
const UMYOVaultABI = require('./UMYOVaultABI.json'); // Your contract ABI

const RPC_URL = process.env.RPC_URL;
const UMYO_VAULT_ADDRESS = process.env.CONTRACT_ADDRESS;
const PRIVATE_KEY = process.env.PRIVATE_KEY;

const MORPHO_GRAPHQL_QUERY = `
  query {
    vaults(
      where: {
        chainId_in: [8453],
        whitelisted: true,
        assetSymbol_in: ["USDC"],
        totalAssetsUsd_gte: 1000000
      }
    ) {
      items {
        address
        symbol
        name
        dailyApys {
          netApy
        }
      }
    }
  }
`;

async function getHighestYieldVault() {
  try {
    const response = await axios.post(
      'https://blue-api.morpho.org/graphql',
      { query: MORPHO_GRAPHQL_QUERY },
      { headers: { 'Content-Type': 'application/json' } }
    );

    const vaults = response.data.data.vaults.items;
    const validVaults = vaults.filter(v => v.dailyApys?.netApy !== undefined);

    if (validVaults.length === 0) {
      throw new Error('No valid vaults found');
    }

    // Sort by APY descending
    validVaults.sort((a, b) => b.dailyApys.netApy - a.dailyApys.netApy);

    return {
      address: validVaults[0].address,
      apy: validVaults[0].dailyApys.netApy,
      name: validVaults[0].name
    };
  } catch (error) {
    console.error('Error fetching vaults:', error);
    throw error;
  }
}

async function optimizeVault() {
  // Setup provider and signer
  const provider = new JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  // Connect to your vault contract
  const vault = new ethers.Contract(UMYO_VAULT_ADDRESS, UMYOVaultABI, signer);

  // Step 1: Get current vault info
  const currentVaultAddress = await vault.morphoVault();
  console.log(`Current Morpho vault: ${currentVaultAddress}`);

  // Step 2: Find highest yield vault
  const bestVault = await getHighestYieldVault();
  console.log(`Highest yield vault: ${bestVault.address} (APY: ${bestVault.apy}%)`);
  
  const currentVault = new ethers.Contract(currentVaultAddress, ['function maxWithdraw(address) view returns (uint256)'], provider);
  const balance = await currentVault.maxWithdraw(vault);
  console.log(`balance:  ${balance}`);

  const shares = await currentVault.maxRedeem(vault);
  console.log(`shares:  ${shares}`);

  // Step 3: Compare and execute if better
  if (currentVaultAddress.toLowerCase() === bestVault.address.toLowerCase()) {
    console.log('Already using the highest yield vault. No action needed.');
    return;
  }

  console.log(`Migrating from ${currentVaultAddress} to ${bestVault.address}...`);
  // Step 4: Withdraw all from current vault
  console.log('Withdrawing from current vault...');
  const tx1 = await vault.withdrawFromMorpho(shares);
  await tx1.wait();
  console.log(`Withdrawal complete: ${tx1.hash}`);

  // Step 5: Update to new vault
  console.log('Updating to new vault...');
  const tx2 = await vault.setMorphoVault(bestVault.address);
  await tx2.wait();
  console.log(`Vault updated: ${tx2.hash}`);

  // Step 6: Deploy to new vault
  console.log('Deploying to new vault...');
  const tx3 = await vault.deployToMorpho();
  await tx3.wait();
  console.log(`Deployment complete: ${tx3.hash}`);

  console.log('Migration successfully completed!');
}

// Run the optimizer
optimizeVault().catch(console.error);
