// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../contracts/UMYOVault.sol";
import "../contracts/FakeMorpho.sol";
import "../contracts/FakeUSDC.sol";

contract UMYOVaultTest is Test {
    UMYOVault vault;
    FakeMorpho morpho;
    FakeUSDC usdc;
    address owner = address(1);
    address user = address(2);

    function setUp() public {
        usdc = new FakeUSDC();
        morpho = new FakeMorpho(address(usdc));
        vault = new UMYOVault(IERC20(address(usdc)));
        
        vault.transferOwnership(owner);
        vm.prank(owner);
        vault.setMorphoVault(IERC4626(address(morpho)));

        // Mint test tokens
        usdc.mint(user, 1000e18);
    }

    function testDepositFlow() public {
        vm.startPrank(user);
        usdc.approve(address(vault), 100e18);
        vault.deposit(100e18, user);
        vm.stopPrank();

        assertEq(vault.balanceOf(user), 100e18);
        assertEq(usdc.balanceOf(address(morpho)), 100e18);
    }

    function testWithdrawWithMorpho() public {
        // 1. Deposit first
        testDepositFlow();

        // 2. Simulate yield (10% APY)
        morpho.setExchangeRate(1.1e18);

        // 3. Withdraw
        vm.prank(user);
        vault.withdraw(110e18, user, user);

        assertEq(usdc.balanceOf(user), 1010e18); // 1000 initial + 110 yield - 100 deposit
    }

    function testOnlyOwnerCanSetVault() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vault.setMorphoVault(IERC4626(address(0)));
    }
}