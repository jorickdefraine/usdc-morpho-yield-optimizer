// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "forge-std/Script.sol";
import "../contracts/UMYOVault.sol";

contract Deploy is Script {
    function run() external {
        // 1. Get env vars
        address usdc = vm.envAddress("USDC_ADDRESS");
        address morphoVault = vm.envAddress("MORPHO_VAULT");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        
        // 2. Start broadcast
        vm.startBroadcast(deployerKey);
        
        // 3. Deploy
        UMYOVault vault = new UMYOVault(IERC20(usdc));
        vault.setMorphoVault(IERC4626(morphoVault));
        
        vm.stopBroadcast();
        
        // 5. Log addresses
        console.log("Vault deployed at:", address(vault));
    }
}