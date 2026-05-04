// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {UMYOVault} from "../contracts/UMYOVault.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";

/**
 * @notice Deployment script for UMYOVault — two-phase owner model.
 *
 * SECURITY MODEL
 * ─────────────
 * The vault enforces strict dual-key separation: the owner approves vault
 * targets and the rebalancer executes fund movements. Both keys must be
 * compromised simultaneously to drain funds. This script enforces that
 * the two roles are assigned to different addresses.
 *
 * TWO-PHASE OWNERSHIP TRANSFER
 * ────────────────────────────
 * Because UMYOVault uses Ownable2Step, ownership transfer is a two-transaction
 * process:
 *   Phase 1 (this script): deployer deploys and configures as temporary owner,
 *                           then initiates transfer to VAULT_OWNER.
 *   Phase 2 (off-chain):   VAULT_OWNER (multisig) calls acceptOwnership() to
 *                           complete the transfer.
 *
 * Until acceptOwnership() is called, the deployer remains the owner. Do not
 * leave this in a partially-transferred state for longer than necessary.
 *
 * Required env vars:
 *   PRIVATE_KEY      — deployer private key (EOA used only for initial setup)
 *   USDC_ADDRESS     — underlying asset
 *   MORPHO_VAULT     — initial Morpho ERC4626 target
 *   VAULT_OWNER      — final owner address (multisig STRONGLY recommended)
 *   REBALANCER       — keeper EOA; MUST differ from VAULT_OWNER
 *
 * Usage:
 *   forge script scripts/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify -vvv
 *
 * After deploy, the multisig must call:
 *   vault.acceptOwnership()
 */
contract Deploy is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("PRIVATE_KEY");
        address deployer     = vm.addr(deployerKey);
        address usdc         = vm.envAddress("USDC_ADDRESS");
        address morphoVault  = vm.envAddress("MORPHO_VAULT");
        address vaultOwner   = vm.envAddress("VAULT_OWNER");
        // vm.envAddress (not envOr) — reverts if REBALANCER is missing.
        // Omitting it is a misconfiguration, not a sensible default.
        address rebalancer   = vm.envAddress("REBALANCER");

        // ── Pre-flight checks ───────────────────────────────────────────────
        require(rebalancer != address(0),  "REBALANCER must be set");
        require(vaultOwner != address(0),  "VAULT_OWNER must be set");
        require(rebalancer != vaultOwner,
            "REBALANCER and VAULT_OWNER must differ: same address collapses the dual-key security model");

        vm.startBroadcast(deployerKey);

        // ── Phase 1a: deploy with the deployer as initial owner ─────────────
        // The deployer must be the owner during setup so that onlyOwner calls
        // below succeed. Ownership is transferred to vaultOwner at the end.
        UMYOVault vault = new UMYOVault(IERC20(usdc), deployer);

        // ── Phase 1b: configure ──────────────────────────────────────────────
        vault.approveVault(morphoVault);
        vault.setMorphoVault(IERC4626(morphoVault));
        vault.setRebalancer(rebalancer);

        // ── Phase 1c: initiate two-step ownership transfer to multisig ───────
        // This only sets pendingOwner — it does NOT change owner() yet.
        // The multisig must call vault.acceptOwnership() to complete the transfer.
        vault.transferOwnership(vaultOwner);

        vm.stopBroadcast();

        console.log("=== UMYOVault Deployment ===");
        console.log("Vault:              ", address(vault));
        console.log("Asset:              ", usdc);
        console.log("Morpho vault:       ", morphoVault);
        console.log("Current owner:      ", deployer, "(temporary, deployer)");
        console.log("Pending owner:      ", vaultOwner, "(multisig, must call acceptOwnership)");
        console.log("Rebalancer:         ", rebalancer);
        console.log("============================");
        console.log("");
        console.log("ACTION REQUIRED:");
        console.log("  1. The multisig at", vaultOwner, "must call vault.acceptOwnership()");
        console.log("     to complete the ownership transfer.");
        console.log("  2. Once ownership is accepted, the deployer key has no further");
        console.log("     admin capabilities.");
        console.log("  3. After users deposit, the keeper calls deployToMorpho().");
    }
}
