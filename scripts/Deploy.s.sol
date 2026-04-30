// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {UMYOVault} from "../contracts/UMYOVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";

/**
 * @notice Deployment script for UMYOVault.
 *
 * Required env vars:
 *   USDC_ADDRESS     — underlying asset
 *   MORPHO_VAULT     — initial Morpho ERC4626 target (can be updated later via rebalance)
 *   VAULT_OWNER      — owner address (multisig recommended in production)
 *   REBALANCER       — keeper address authorized to call rebalance/deployToMorpho
 *   PRIVATE_KEY      — deployer private key
 *
 * Usage:
 *   forge script scripts/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify -vvv
 */
contract Deploy is Script {
    function run() external {
        address usdc       = vm.envAddress("USDC_ADDRESS");
        address morphoVault = vm.envAddress("MORPHO_VAULT");
        address vaultOwner = vm.envAddress("VAULT_OWNER");
        address rebalancer = vm.envOr("REBALANCER", vaultOwner); // fallback to owner if not set
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        UMYOVault vault = new UMYOVault(IERC20(usdc), vaultOwner);
        vault.approveVault(morphoVault);
        vault.setMorphoVault(IERC4626(morphoVault));
        vault.setRebalancer(rebalancer);

        vm.stopBroadcast();

        console.log("=== UMYOVault Deployment ===");
        console.log("Vault:      ", address(vault));
        console.log("Asset:      ", usdc);
        console.log("Morpho:     ", morphoVault);
        console.log("Owner:      ", vaultOwner);
        console.log("Rebalancer: ", rebalancer);
        console.log("============================");
        console.log("Next: call deployToMorpho() after users deposit.");
        console.log("ABI: forge inspect UMYOVault abi > scripts/UMYOVaultABI.json");
    }
}
