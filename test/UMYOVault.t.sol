// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "forge-std/Test.sol";
import "../contracts/UMYOVault.sol";
import "../contracts/FakeMorpho.sol";
import "../contracts/FakeUSDC.sol";

contract UMYOVault_Test is Test {
    UMYOVault vault;
    FakeMorpho morpho;
    FakeUSDC usdc;
    address owner = address(1);
    address user = address(2);

    function setUp() public {
    usdc = new FakeUSDC();
    morpho = new FakeMorpho(IERC20(address(usdc)));
    vault = new UMYOVault(IERC20(address(usdc)));
    
    vault.transferOwnership(owner);
    vm.prank(owner);
    vault.setMorphoVault(IERC4626(address(morpho)));

    usdc.mint(user, 1000e18);
}

function testDepositFlow() public {
    vm.startPrank(user);
    usdc.approve(address(vault), 100e18);
    vault.deposit(100e18, user);
    vm.stopPrank();

    assertEq(vault.balanceOf(user), 100e18);
    
    vm.prank(owner);
    vault.deployToMorpho();
    assertEq(usdc.balanceOf(address(morpho)), 100e18);
}

function testWithdrawWithMorpho() public {
    testDepositFlow();
    
    vm.prank(user);
    vault.withdraw(100e18, user, user); 
    
    assertGt(usdc.balanceOf(user), 100e18);
}
}