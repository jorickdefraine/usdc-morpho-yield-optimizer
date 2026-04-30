// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {UMYOVault} from "../contracts/UMYOVault.sol";
import {FakeMorpho} from "../contracts/FakeMorpho.sol";
import {FakeUSDC} from "../contracts/FakeUSDC.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";

// Mirrors events from UMYOVault for vm.expectEmit assertions
// (Solidity does not allow referencing events as ContractType.EventName)
interface IUMYOVaultEvents {
    event VaultApprovalChanged(address indexed vault, bool approved);
}

contract UMYOVaultTest is Test, IUMYOVaultEvents {
    UMYOVault  vault;
    FakeMorpho morpho1;
    FakeMorpho morpho2;
    FakeUSDC   usdc;

    address owner     = makeAddr("owner");
    address keeper    = makeAddr("keeper");
    address alice     = makeAddr("alice");
    address bob       = makeAddr("bob");
    address attacker  = makeAddr("attacker");

    uint256 constant ONE_USDC     = 1e6;
    uint256 constant THOUSAND     = 1_000 * ONE_USDC;
    uint256 constant TEN_THOUSAND = 10_000 * ONE_USDC;
    // _decimalsOffset = 6 → 10^6 shares minted per µUSDC at empty vault
    uint256 constant SHARE_SCALE  = 10 ** 6;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        usdc    = new FakeUSDC();
        morpho1 = new FakeMorpho(IERC20(address(usdc)));
        morpho2 = new FakeMorpho(IERC20(address(usdc)));
        vault   = new UMYOVault(IERC20(address(usdc)), owner);

        vm.startPrank(owner);
        vault.approveVault(address(morpho1));
        vault.approveVault(address(morpho2));
        vault.setMorphoVault(IERC4626(address(morpho1)));
        vault.setRebalancer(keeper);
        vm.stopPrank();

        usdc.mint(alice, TEN_THOUSAND);
        usdc.mint(bob,   TEN_THOUSAND);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _deposit(address user, uint256 assets) internal returns (uint256 shares) {
        vm.startPrank(user);
        usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function _deployAll() internal {
        vm.prank(keeper);
        vault.deployToMorpho(0);
    }

    // =========================================================================
    // Deployment and initialization
    // =========================================================================

    function test_InitialState() public view {
        assertEq(vault.owner(), owner);
        assertEq(vault.rebalancer(), keeper);
        assertEq(address(vault.morphoVault()), address(morpho1));
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }

    // =========================================================================
    // Deposit and share accounting
    // =========================================================================

    function test_DepositMintsShares() public {
        uint256 shares = _deposit(alice, THOUSAND);
        // With _decimalsOffset = 6: shares = assets * 10^6 at an empty vault
        assertEq(shares, THOUSAND * SHARE_SCALE, "shares proportional to assets with offset");
        assertEq(vault.balanceOf(alice), THOUSAND * SHARE_SCALE);
        assertEq(vault.totalAssets(), THOUSAND);
        assertEq(usdc.balanceOf(address(vault)), THOUSAND);
    }

    function test_DepositDeployToMorpho() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        assertEq(usdc.balanceOf(address(vault)), 0, "vault holds no idle USDC");
        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND, "morpho1 holds the USDC");
        assertEq(vault.totalAssets(), THOUSAND, "totalAssets unchanged");
    }

    function test_MultipleDepositorShareAccounting() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        // Simulate 10% yield before bob deposits
        morpho1.simulateYield(100 * ONE_USDC);
        // vault now has 1100 USDC worth of assets, 1000 USDC worth of shares outstanding
        // Bob deposits 1100 USDC → should get an equal value to alice
        _deposit(bob, 1_100 * ONE_USDC);

        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1_100 * ONE_USDC, 2);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)),   1_100 * ONE_USDC, 2);
    }

    // =========================================================================
    // Withdraw
    // =========================================================================

    function test_WithdrawLocal() public {
        _deposit(alice, THOUSAND);
        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND, "alice gets all USDC back");
        assertEq(vault.totalAssets(), 0);
    }

    function test_WithdrawRecallsFromMorpho() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND, "alice gets all USDC back");
        assertEq(usdc.balanceOf(address(morpho1)), 0, "morpho drained");
        assertEq(vault.totalAssets(), 0);
    }

    function test_WithdrawPartialFromMorpho() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(alice);
        vault.withdraw(500 * ONE_USDC, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND - 500 * ONE_USDC);
        assertApproxEqAbs(vault.totalAssets(), 500 * ONE_USDC, 1);
    }

    function test_WithdrawAfterYield() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        morpho1.simulateYield(100 * ONE_USDC);

        uint256 expectedAssets = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqAbs(expectedAssets, 1_100 * ONE_USDC, 2);

        uint256 before = usdc.balanceOf(alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, 1_100 * ONE_USDC, 2);
    }

    function test_WithdrawRevertsOnInsufficientLiquidity() public {
        _deposit(alice, THOUSAND);
        _deployAll();
        morpho1.simulateLoss(500 * ONE_USDC);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(UMYOVault.InsufficientLiquidity.selector, THOUSAND, 500 * ONE_USDC));
        vault.withdraw(THOUSAND, alice, alice);
    }

    // =========================================================================
    // Redeem
    // =========================================================================

    function test_RedeemBurnsSharesForAssets() public {
        uint256 shares = _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, THOUSAND);
        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_RedeemWithYieldReturnsMoreAssets() public {
        uint256 shares = _deposit(alice, THOUSAND);
        _deployAll();
        morpho1.simulateYield(100 * ONE_USDC);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(assets, 1_100 * ONE_USDC, 2, "yield should be captured");
        assertGt(usdc.balanceOf(alice), TEN_THOUSAND - THOUSAND, "net gain vs deposit");
    }

    // =========================================================================
    // Rebalance
    // =========================================================================

    function test_RebalanceMigratesAllFunds() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);

        vm.prank(keeper);
        vault.rebalance(address(morpho2), THOUSAND - 1, 0);

        assertEq(usdc.balanceOf(address(morpho1)), 0, "old vault drained");
        assertEq(usdc.balanceOf(address(morpho2)), THOUSAND, "new vault funded");
        assertEq(address(vault.morphoVault()), address(morpho2));
        assertEq(vault.totalAssets(), THOUSAND);
    }

    function test_RebalanceUpdatesPreviousVault() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(keeper);
        vault.rebalance(address(morpho2), 0, 0);

        assertEq(vault.previousMorphoVault(), address(morpho1));
    }

    function test_RebalanceFromNoVault() public {
        UMYOVault freshVault = new UMYOVault(IERC20(address(usdc)), owner);
        usdc.mint(address(freshVault), THOUSAND);

        vm.startPrank(owner);
        freshVault.approveVault(address(morpho1));
        freshVault.setRebalancer(keeper);
        vm.stopPrank();

        vm.prank(keeper);
        freshVault.rebalance(address(morpho1), 0, 0);

        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);
        assertEq(address(freshVault.morphoVault()), address(morpho1));
    }

    function test_RebalanceSlippageProtectionOnRecall() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        morpho1.simulateLoss(200 * ONE_USDC);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(UMYOVault.SlippageExceeded.selector, 800 * ONE_USDC, 900 * ONE_USDC));
        vault.rebalance(address(morpho2), 900 * ONE_USDC, 0);

        assertEq(usdc.balanceOf(address(morpho1)), 800 * ONE_USDC);
    }

    function test_RebalanceSlippageProtectionOnDeploy() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        // Compute how many shares to expect from morpho2 for THOUSAND USDC
        uint256 expectedShares = morpho2.previewDeposit(THOUSAND);

        // Demand more shares than morpho2 can possibly give → should revert
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(UMYOVault.SlippageExceeded.selector, expectedShares, expectedShares + 1)
        );
        vault.rebalance(address(morpho2), 0, expectedShares + 1);
    }

    function test_RebalanceSameVaultReverts() public {
        vm.prank(keeper);
        vm.expectRevert(UMYOVault.SameVault.selector);
        vault.rebalance(address(morpho1), 0, 0);
    }

    function test_RebalanceZeroAddressReverts() public {
        vm.prank(keeper);
        vm.expectRevert(UMYOVault.ZeroAddress.selector);
        vault.rebalance(address(0), 0, 0);
    }

    function test_RebalanceUnapprovedVaultReverts() public {
        FakeMorpho morpho3 = new FakeMorpho(IERC20(address(usdc)));

        vm.prank(keeper);
        vm.expectRevert(UMYOVault.VaultNotApproved.selector);
        vault.rebalance(address(morpho3), 0, 0);
    }

    function test_RebalanceAssetMismatchReverts() public {
        // Deploy a vault with a different underlying token
        FakeUSDC otherToken = new FakeUSDC();
        FakeMorpho wrongAssetMorpho = new FakeMorpho(IERC20(address(otherToken)));

        vm.prank(owner);
        vault.approveVault(address(wrongAssetMorpho));

        vm.prank(keeper);
        vm.expectRevert(UMYOVault.AssetMismatch.selector);
        vault.rebalance(address(wrongAssetMorpho), 0, 0);
    }

    function test_UserCanWithdrawAfterRebalance() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(keeper);
        vault.rebalance(address(morpho2), 0, 0);

        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
    }

    // =========================================================================
    // Rebalance cooldown
    // =========================================================================

    function test_RebalanceCooldownBlocksSecondRebalance() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(owner);
        vault.setRebalanceCooldown(1 hours);

        vm.prank(keeper);
        vault.rebalance(address(morpho2), 0, 0);

        // Immediately try again (morpho1 is now approved and != current)
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                UMYOVault.RebalanceCooldownActive.selector,
                vault.lastRebalanceTime() + 1 hours
            )
        );
        vault.rebalance(address(morpho1), 0, 0);
    }

    function test_RebalanceCooldownAllowsAfterExpiry() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(owner);
        vault.setRebalanceCooldown(1 hours);

        vm.prank(keeper);
        vault.rebalance(address(morpho2), 0, 0);

        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(keeper);
        vault.rebalance(address(morpho1), 0, 0); // should succeed

        assertEq(address(vault.morphoVault()), address(morpho1));
    }

    // =========================================================================
    // deployToMorpho slippage
    // =========================================================================

    function test_DeployToMorphoSlippageReverts() public {
        _deposit(alice, THOUSAND);

        uint256 expectedShares = morpho1.previewDeposit(THOUSAND);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(UMYOVault.SlippageExceeded.selector, expectedShares, expectedShares + 1)
        );
        vault.deployToMorpho(expectedShares + 1);
    }

    function test_DeployToMorphoSlippagePassesWithZero() public {
        _deposit(alice, THOUSAND);
        vm.prank(keeper);
        vault.deployToMorpho(0); // no slippage floor → always succeeds
        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);
    }

    // =========================================================================
    // Access control
    // =========================================================================

    function test_OnlyOwnerCanSetMorphoVault() public {
        FakeMorpho morpho3 = new FakeMorpho(IERC20(address(usdc)));
        vm.prank(owner);
        vault.approveVault(address(morpho3));

        vm.prank(attacker);
        vm.expectRevert();
        vault.setMorphoVault(IERC4626(address(morpho3)));
    }

    function test_OnlyOwnerCanSetRebalancer() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setRebalancer(attacker);
    }

    function test_OnlyOwnerOrRebalancerCanRecall() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        // Attacker cannot recall
        vm.prank(attacker);
        vm.expectRevert(UMYOVault.Unauthorized.selector);
        vault.recallFromMorpho();

        // Rebalancer (keeper) can recall
        vm.prank(keeper);
        vault.recallFromMorpho();
        assertEq(usdc.balanceOf(address(vault)), THOUSAND);

        // Redeploy and confirm owner can also recall
        _deployAll();
        vm.prank(owner);
        vault.recallFromMorpho();
        assertEq(usdc.balanceOf(address(vault)), THOUSAND);
    }

    function test_OnlyRebalancerCanDeploy() public {
        _deposit(alice, THOUSAND);

        // Owner can no longer call deployToMorpho (roles are separated)
        vm.prank(owner);
        vm.expectRevert(UMYOVault.Unauthorized.selector);
        vault.deployToMorpho(0);

        vm.prank(attacker);
        vm.expectRevert(UMYOVault.Unauthorized.selector);
        vault.deployToMorpho(0);

        vm.prank(keeper);
        vault.deployToMorpho(0); // keeper succeeds
    }

    function test_OwnerCannotRebalanceDirectly() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        // Owner role is separated from rebalancer: cannot call rebalance()
        vm.prank(owner);
        vm.expectRevert(UMYOVault.Unauthorized.selector);
        vault.rebalance(address(morpho2), 0, 0);
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_DepositRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        usdc.approve(address(vault), THOUSAND);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        vault.deposit(THOUSAND, alice);
    }

    function test_MintRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        usdc.approve(address(vault), THOUSAND);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vm.prank(alice);
        vault.mint(THOUSAND * SHARE_SCALE, alice);
    }

    function test_WithdrawAndRedeemWorkWhilePaused() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(owner);
        vault.pause();

        // Withdrawals must still work during pause
        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
    }

    function test_UnpauseRestoresDeposits() public {
        vm.startPrank(owner);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        uint256 shares = _deposit(alice, THOUSAND);
        assertGt(shares, 0);
    }

    // =========================================================================
    // Vault whitelist
    // =========================================================================

    function test_ApproveVaultEmitsEvent() public {
        FakeMorpho morpho3 = new FakeMorpho(IERC20(address(usdc)));

        vm.expectEmit(true, false, false, true, address(vault));
        emit VaultApprovalChanged(address(morpho3), true);

        vm.prank(owner);
        vault.approveVault(address(morpho3));

        assertTrue(vault.approvedVaults(address(morpho3)));
    }

    function test_RevokeVaultBlocksRebalance() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(owner);
        vault.revokeVault(address(morpho2));

        vm.prank(keeper);
        vm.expectRevert(UMYOVault.VaultNotApproved.selector);
        vault.rebalance(address(morpho2), 0, 0);
    }

    // =========================================================================
    // setMorphoVault guards
    // =========================================================================

    function test_SetMorphoVaultRevertsOnSameVault() public {
        vm.prank(owner);
        vm.expectRevert(UMYOVault.SameVault.selector);
        vault.setMorphoVault(IERC4626(address(morpho1)));
    }

    function test_SetMorphoVaultRevertsWhenNotApproved() public {
        FakeMorpho morpho3 = new FakeMorpho(IERC20(address(usdc)));

        vm.prank(owner);
        vm.expectRevert(UMYOVault.VaultNotApproved.selector);
        vault.setMorphoVault(IERC4626(address(morpho3)));
    }

    function test_SetMorphoVaultRevertsWithDeployedFunds() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        FakeMorpho morpho3 = new FakeMorpho(IERC20(address(usdc)));

        vm.startPrank(owner);
        vault.approveVault(address(morpho3));
        vm.expectRevert(UMYOVault.VaultHasDeployedFunds.selector);
        vault.setMorphoVault(IERC4626(address(morpho3)));
        vm.stopPrank();
    }

    function test_SetMorphoVaultRevertsOnAssetMismatch() public {
        FakeUSDC otherToken = new FakeUSDC();
        FakeMorpho wrongAsset = new FakeMorpho(IERC20(address(otherToken)));

        vm.startPrank(owner);
        vault.approveVault(address(wrongAsset));
        vm.expectRevert(UMYOVault.AssetMismatch.selector);
        vault.setMorphoVault(IERC4626(address(wrongAsset)));
        vm.stopPrank();
    }

    function test_SetMorphoVaultUpdatesPreviousVault() public {
        // Recall all funds so setMorphoVault is allowed
        _deposit(alice, THOUSAND);
        _deployAll();
        vm.prank(owner);
        vault.recallFromMorpho();

        FakeMorpho morpho3 = new FakeMorpho(IERC20(address(usdc)));
        vm.startPrank(owner);
        vault.approveVault(address(morpho3));
        vault.setMorphoVault(IERC4626(address(morpho3)));
        vm.stopPrank();

        assertEq(vault.previousMorphoVault(), address(morpho1));
        assertEq(address(vault.morphoVault()), address(morpho3));
    }

    // =========================================================================
    // Reward sweeping
    // =========================================================================

    function test_SweepRewardsSendsTokensToOwner() public {
        FakeUSDC rewardToken = new FakeUSDC();
        rewardToken.mint(address(vault), 500 * ONE_USDC);

        vm.prank(owner);
        vault.sweepRewards(address(rewardToken));

        assertEq(rewardToken.balanceOf(owner), 500 * ONE_USDC, "owner receives rewards");
        assertEq(rewardToken.balanceOf(address(vault)), 0, "vault drained");
    }

    function test_SweepRevertsOnUnderlying() public {
        _deposit(alice, THOUSAND);

        vm.prank(owner);
        vm.expectRevert(UMYOVault.CannotSweepUnderlying.selector);
        vault.sweepRewards(address(usdc));
    }

    function test_SweepRevertsOnMorphoShares() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        // Attempting to sweep the active Morpho vault shares would drain all deployed funds
        vm.prank(owner);
        vm.expectRevert(UMYOVault.CannotSweepUnderlying.selector);
        vault.sweepRewards(address(morpho1));
    }

    function test_SweepRevertsOnPreviousMorphoShares() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(keeper);
        vault.rebalance(address(morpho2), 0, 0);

        // morpho1 is now previousMorphoVault — cannot sweep residual shares
        vm.prank(owner);
        vm.expectRevert(UMYOVault.CannotSweepUnderlying.selector);
        vault.sweepRewards(address(morpho1));
    }

    function test_SweepRevertsForNonOwner() public {
        FakeUSDC rewardToken = new FakeUSDC();
        rewardToken.mint(address(vault), 500 * ONE_USDC);

        vm.prank(attacker);
        vm.expectRevert();
        vault.sweepRewards(address(rewardToken));
    }

    // =========================================================================
    // Emergency recall
    // =========================================================================

    function test_RecallFromMorpho() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(owner);
        vault.recallFromMorpho();

        assertEq(usdc.balanceOf(address(vault)), THOUSAND, "assets back to vault");
        assertEq(usdc.balanceOf(address(morpho1)), 0, "morpho1 drained");
        assertEq(vault.totalAssets(), THOUSAND, "totalAssets preserved");
    }

    function test_RecallThenRedeploy() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(owner);
        vault.recallFromMorpho();

        vm.prank(keeper);
        vault.deployToMorpho(0);

        assertEq(usdc.balanceOf(address(vault)), 0);
        assertEq(vault.totalAssets(), THOUSAND);
    }

    // =========================================================================
    // maxWithdraw / maxRedeem (EIP-4626 compliance)
    // =========================================================================

    function test_MaxWithdrawEqualsUserEntitlement() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        uint256 maxW = vault.maxWithdraw(alice);
        assertApproxEqAbs(maxW, THOUSAND, 1);
    }

    function test_MaxWithdrawCappedByMorphoLiquidity() public {
        _deposit(alice, THOUSAND);
        _deployAll();
        morpho1.simulateLoss(600 * ONE_USDC);

        uint256 maxW = vault.maxWithdraw(alice);
        assertApproxEqAbs(maxW, 400 * ONE_USDC, 1);
    }

    function test_MaxWithdrawIsHonoured() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        uint256 maxW = vault.maxWithdraw(alice);

        // withdraw(maxWithdraw) MUST NOT revert per EIP-4626
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice);
    }

    function test_MaxRedeemIsHonoured() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        uint256 maxR = vault.maxRedeem(alice);

        vm.prank(alice);
        vault.redeem(maxR, alice, alice);
    }

    // =========================================================================
    // Fuzz tests
    // =========================================================================

    function testFuzz_DepositWithdraw(uint96 amount) public {
        vm.assume(amount >= ONE_USDC && amount <= TEN_THOUSAND);

        usdc.mint(alice, amount);
        uint256 balBefore = usdc.balanceOf(alice);

        uint256 shares = _deposit(alice, amount);
        _deployAll();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertApproxEqAbs(usdc.balanceOf(alice), balBefore, 1, "no loss on round-trip");
        assertEq(vault.totalAssets(), 0);
    }

    function testFuzz_MultiDeposit(uint96 a, uint96 b) public {
        vm.assume(a >= ONE_USDC && a <= TEN_THOUSAND / 2);
        vm.assume(b >= ONE_USDC && b <= TEN_THOUSAND / 2);

        usdc.mint(alice, a);
        usdc.mint(bob,   b);

        _deposit(alice, a);
        _deposit(bob,   b);
        _deployAll();

        uint256 totalShares = vault.totalSupply();
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares   = vault.balanceOf(bob);

        assertEq(aliceShares + bobShares, totalShares);

        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);

        assertApproxEqAbs(vault.totalAssets(), 0, 1);
    }

    // =========================================================================
    // Invariant tests
    // =========================================================================

    function testInvariant_SharePriceMonotonicallyIncreases() public {
        uint256 before = usdc.balanceOf(alice);

        _deposit(alice, THOUSAND);
        _deployAll();

        morpho1.simulateYield(50 * ONE_USDC);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertGe(usdc.balanceOf(alice), before + 50 * ONE_USDC - 2, "yield captured");
    }

    function testInvariant_TotalAssetsConsistency() public {
        _deposit(alice, THOUSAND);
        _deposit(bob,   2 * THOUSAND);
        _deployAll();

        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobAssets   = vault.convertToAssets(vault.balanceOf(bob));

        assertLe(
            aliceAssets + bobAssets,
            vault.totalAssets() + 2,
            "sum of claims must not exceed vault holdings"
        );
    }
}
