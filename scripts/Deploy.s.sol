// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {UMYOVault} from "../contracts/UMYOVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";

/**
 * @notice Deployment script for UMYOVault v1.2.0
 *
 * TWO-PHASE OWNERSHIP TRANSFER
 * ────────────────────────────
 * Phase 1 (this script): deployer sets up the vault, then calls transferOwnership(VAULT_OWNER).
 * Phase 2 (off-chain):   VAULT_OWNER (multisig) calls acceptOwnership() to finalise.
 *
 * Required env vars:
 *   PRIVATE_KEY      — deployer EOA (discarded after Phase 2)
 *   USDC_ADDRESS     — underlying token (USDC on Base)
 *   MORPHO_VAULT     — initial Morpho ERC4626 vault to whitelist
 *   VAULT_OWNER      — final owner (multisig strongly recommended)
 *   KEEPER           — keeper EOA that may call rebalance()
 *
 * Usage:
 *   forge script scripts/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify -vvv
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address usdc        = vm.envAddress("USDC_ADDRESS");
        address morphoVault = vm.envAddress("MORPHO_VAULT");
        address vaultOwner  = vm.envAddress("VAULT_OWNER");
        address keeperAddr  = vm.envAddress("KEEPER");

        require(vaultOwner != address(0), "VAULT_OWNER must be set");
        require(keeperAddr != address(0), "KEEPER must be set");

        vm.startBroadcast(deployerKey);

        // Deploy — deployer is temporary owner during setup.
        UMYOVault vault = new UMYOVault(IERC20(usdc), deployer, keeperAddr);

        // Whitelist initial Morpho vault.
        vault.allowVault(morphoVault, true);

        // Initiate two-step ownership transfer. Does NOT change owner() yet.
        // Multisig must call vault.acceptOwnership() to complete.
        vault.transferOwnership(vaultOwner);

        vm.stopBroadcast();

        console.log("=== UMYOVault v1.2.0 Deployment ===");
        console.log("Vault:         ", address(vault));
        console.log("Asset:         ", usdc);
        console.log("Morpho vault:  ", morphoVault);
        console.log("Temp owner:    ", deployer, "(deployer, pending transfer)");
        console.log("Pending owner: ", vaultOwner, "(multisig, call acceptOwnership)");
        console.log("Keeper:        ", keeperAddr);
        console.log("===================================");
        console.log("ACTION REQUIRED: multisig at", vaultOwner, "must call acceptOwnership()");
    }
}
