// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {UMYOVault} from "../contracts/UMYOVault.sol";
import {FakeMorpho} from "../contracts/FakeMorpho.sol";
import {FakeUSDC} from "../contracts/FakeUSDC.sol";
import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";

// =========================================================================
// Malicious ERC4626 that attempts reentrancy during redeem
// =========================================================================
contract ReentrantMarket is ERC4626 {
    UMYOVault internal _vault;
    address   internal _target;

    constructor(IERC20 _asset) ERC4626(_asset) ERC20("Reentrant", "RE") {}

    function configure(UMYOVault vault, address target) external {
        _vault  = vault;
        _target = target;
    }

    /// @dev On redeem, silently tries to reenter vault.rebalance(). The nonReentrant
    ///      guard will block it. The try-catch makes it a realistic stealth attack.
    function redeem(uint256 shares, address receiver, address owner_)
        public override returns (uint256 assets)
    {
        assets = super.redeem(shares, receiver, owner_);
        try _vault.rebalance(_target) {} catch {}
    }
}

// =========================================================================
// Fake Morpho Universal Rewards Distributor
// =========================================================================
contract FakeDistributor {
    function claim(address account, address reward, uint256 claimable, bytes32[] calldata) external {
        FakeUSDC(reward).mint(account, claimable);
    }
}

// =========================================================================
// Test suite
// =========================================================================
contract UMYOVaultTest is Test {
    UMYOVault  vault;
    FakeMorpho morpho1;
    FakeMorpho morpho2;
    FakeUSDC   usdc;

    address owner    = makeAddr("owner");
    address keeper   = makeAddr("keeper");
    address alice    = makeAddr("alice");
    address bob      = makeAddr("bob");
    address attacker = makeAddr("attacker");

    uint256 constant ONE_USDC     = 1e6;
    uint256 constant THOUSAND     = 1_000 * ONE_USDC;
    uint256 constant TEN_THOUSAND = 10_000 * ONE_USDC;
    uint256 constant SHARE_SCALE  = 10 ** 6; // _decimalsOffset = 6

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        usdc    = new FakeUSDC();
        morpho1 = new FakeMorpho(IERC20(address(usdc)));
        morpho2 = new FakeMorpho(IERC20(address(usdc)));

        vault = new UMYOVault(IERC20(address(usdc)), owner, keeper);

        vm.startPrank(owner);
        vault.allowVault(address(morpho1), true);
        vault.allowVault(address(morpho2), true);
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

    /// Deploy all idle USDC to morpho1.
    function _deployToMorpho1() internal {
        vm.prank(keeper);
        vault.rebalance(address(morpho1));
    }

    // =========================================================================
    // Initial state
    // =========================================================================

    function test_InitialState() public view {
        assertEq(vault.owner(),   owner);
        assertEq(vault.keeper(),  keeper);
        assertEq(address(vault.morphoVault()), address(0));
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
        assertEq(vault.VERSION(), "1.2.0");
    }

    // =========================================================================
    // Deposit
    // =========================================================================

    function test_DepositMintsShares() public {
        uint256 shares = _deposit(alice, THOUSAND);
        // _decimalsOffset = 6: at empty vault, shares = assets * 10^6
        assertEq(shares, THOUSAND * SHARE_SCALE);
        assertEq(vault.balanceOf(alice), THOUSAND * SHARE_SCALE);
        assertEq(vault.totalAssets(), THOUSAND);
        assertEq(usdc.balanceOf(address(vault)), THOUSAND);
    }

    function test_DepositDeployedViaRebalance() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        assertEq(usdc.balanceOf(address(vault)),   0,       "nothing idle after deploy");
        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND, "all in morpho1");
        assertEq(vault.totalAssets(), THOUSAND,              "totalAssets unchanged");
    }

    function test_MultipleDepositorShareAccounting() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        // 10% yield before bob deposits.
        morpho1.simulateYield(100 * ONE_USDC);

        _deposit(bob, 1_100 * ONE_USDC);

        // Both should own equal value.
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1_100 * ONE_USDC, 2);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)),   1_100 * ONE_USDC, 2);
    }

    // =========================================================================
    // Withdraw
    // =========================================================================

    function test_WithdrawFromIdle() public {
        _deposit(alice, THOUSAND);
        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
        assertEq(vault.totalAssets(), 0);
    }

    function test_WithdrawRecallsFromMorpho() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
        assertEq(usdc.balanceOf(address(morpho1)), 0, "morpho fully recalled");
        assertEq(vault.totalAssets(), 0);
    }

    function test_WithdrawPartialRecallsFromMorpho() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(alice);
        vault.withdraw(500 * ONE_USDC, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND - 500 * ONE_USDC);
        assertApproxEqAbs(vault.totalAssets(), 500 * ONE_USDC, 1);
    }

    function test_WithdrawAfterYield() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();
        morpho1.simulateYield(100 * ONE_USDC);

        uint256 before      = usdc.balanceOf(alice);
        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, 1_100 * ONE_USDC, 2);
    }

    function test_WithdrawRevertsOnInsufficientLiquidity() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();
        morpho1.simulateLoss(500 * ONE_USDC);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(
            UMYOVault.InsufficientLiquidity.selector, THOUSAND, 500 * ONE_USDC
        ));
        vault.withdraw(THOUSAND, alice, alice);
    }

    // =========================================================================
    // Redeem
    // =========================================================================

    function test_RedeemBurnsShares() public {
        uint256 shares = _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertEq(assets, THOUSAND);
        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_RedeemWithYieldReturnsMore() public {
        uint256 shares = _deposit(alice, THOUSAND);
        _deployToMorpho1();
        morpho1.simulateYield(100 * ONE_USDC);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(assets, 1_100 * ONE_USDC, 2);
    }

    // =========================================================================
    // Rebalance — normal flows
    // =========================================================================

    function test_RebalanceMigratesAllFunds() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);

        vm.prank(keeper);
        vault.rebalance(address(morpho2));

        assertEq(usdc.balanceOf(address(morpho1)), 0,        "old market drained");
        assertEq(usdc.balanceOf(address(morpho2)), THOUSAND, "new market funded");
        assertEq(address(vault.morphoVault()), address(morpho2));
        assertEq(vault.totalAssets(), THOUSAND);
    }

    function test_RebalanceSameVaultDeploysIdle() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();   // 1,000 in morpho1

        _deposit(bob, THOUSAND); // 1,000 sits idle

        // Keeper redeploys idle by calling rebalance with the same market.
        vm.prank(keeper);
        vault.rebalance(address(morpho1));

        assertEq(usdc.balanceOf(address(morpho1)), 2 * THOUSAND, "all deployed");
        assertEq(usdc.balanceOf(address(vault)), 0,               "nothing idle");
    }

    function test_RebalanceMultipleVaults() public {
        _deposit(alice, THOUSAND);

        // Deploy to morpho1.
        vm.prank(keeper);
        vault.rebalance(address(morpho1));
        assertEq(address(vault.morphoVault()), address(morpho1));

        // Migrate to morpho2.
        vm.prank(keeper);
        vault.rebalance(address(morpho2));
        assertEq(address(vault.morphoVault()), address(morpho2));
        assertEq(usdc.balanceOf(address(morpho1)), 0);
        assertEq(usdc.balanceOf(address(morpho2)), THOUSAND);

        // Migrate back to morpho1.
        vm.prank(keeper);
        vault.rebalance(address(morpho1));
        assertEq(address(vault.morphoVault()), address(morpho1));
        assertEq(usdc.balanceOf(address(morpho2)), 0);
        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);
    }

    function test_RebalanceInitialDeploy_NoOldVault() public {
        // Vault has no market set yet — first rebalance deploys idle USDC.
        assertEq(address(vault.morphoVault()), address(0));
        usdc.mint(address(vault), THOUSAND);

        vm.prank(keeper);
        vault.rebalance(address(morpho1));

        assertEq(address(vault.morphoVault()), address(morpho1));
        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);
    }

    function test_UserCanWithdrawAfterRebalance() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(keeper);
        vault.rebalance(address(morpho2));

        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
    }

    // =========================================================================
    // Rebalance — attack: malicious keeper input
    // =========================================================================

    function test_KeeperCannotRouteToUnapprovedVault() public {
        FakeMorpho malicious = new FakeMorpho(IERC20(address(usdc)));
        // NOT in allowedVaults

        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(keeper);
        vm.expectRevert(UMYOVault.VaultNotAllowed.selector);
        vault.rebalance(address(malicious));

        // Funds are still safe in morpho1.
        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);
    }

    function test_RebalanceRevertsOnAssetMismatch() public {
        FakeUSDC otherToken = new FakeUSDC();
        FakeMorpho wrongAsset = new FakeMorpho(IERC20(address(otherToken)));

        vm.prank(owner);
        vault.allowVault(address(wrongAsset), true);

        vm.prank(keeper);
        vm.expectRevert(UMYOVault.AssetMismatch.selector);
        vault.rebalance(address(wrongAsset));
    }

    function test_RebalanceRevertsOnZeroAddress() public {
        vm.prank(keeper);
        vm.expectRevert(UMYOVault.ZeroAddress.selector);
        vault.rebalance(address(0));
    }

    function test_AttackerCannotCallRebalance() public {
        vm.prank(attacker);
        vm.expectRevert(UMYOVault.Unauthorized.selector);
        vault.rebalance(address(morpho1));
    }

    // =========================================================================
    // Rebalance — attack: reentrancy
    // =========================================================================

    function test_ReentrancyOnRebalanceIsBlocked() public {
        // A ReentrantMarket silently attempts to call vault.rebalance() during
        // its own redeem(). The nonReentrant guard should block the inner call
        // but allow the outer rebalance to complete normally.

        ReentrantMarket reentrant = new ReentrantMarket(IERC20(address(usdc)));
        reentrant.configure(vault, address(morpho2));

        vm.prank(owner);
        vault.allowVault(address(reentrant), true);

        // Deploy funds to the reentrant market.
        _deposit(alice, THOUSAND);
        vm.prank(keeper);
        vault.rebalance(address(reentrant));
        assertEq(IERC20(address(usdc)).balanceOf(address(reentrant)), THOUSAND);

        // Rebalance away — during redeem, the reentrant market tries to call
        // vault.rebalance(morpho2) but the nonReentrant guard blocks it.
        // The outer rebalance completes; funds end up in morpho2.
        vm.prank(keeper);
        vault.rebalance(address(morpho2));

        // Funds are in morpho2 as intended, not in reentrant or stolen.
        assertEq(usdc.balanceOf(address(morpho2)), THOUSAND, "funds safe in morpho2");
        assertEq(usdc.balanceOf(address(reentrant)), 0,       "reentrant drained");
    }

    // =========================================================================
    // Emergency withdraw
    // =========================================================================

    function test_EmergencyWithdraw() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(owner);
        vault.emergencyWithdraw();

        assertEq(usdc.balanceOf(address(vault)),   THOUSAND, "funds returned to vault");
        assertEq(usdc.balanceOf(address(morpho1)), 0,        "morpho fully drained");
        assertEq(vault.totalAssets(), THOUSAND,               "totalAssets preserved");
    }

    function test_EmergencyWithdrawWhenEmpty() public {
        // Should not revert when nothing is deployed.
        vm.prank(owner);
        vault.emergencyWithdraw();
    }

    function test_EmergencyWithdrawWorksWhenPaused() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.startPrank(owner);
        vault.pause();
        vault.emergencyWithdraw(); // must succeed even when paused
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), THOUSAND);
    }

    function test_OnlyOwnerCanEmergencyWithdraw() public {
        vm.prank(keeper);
        vm.expectRevert();
        vault.emergencyWithdraw();

        vm.prank(attacker);
        vm.expectRevert();
        vault.emergencyWithdraw();
    }

    // =========================================================================
    // Access control
    // =========================================================================

    function test_OnlyOwnerCanAllowVault() public {
        FakeMorpho m = new FakeMorpho(IERC20(address(usdc)));
        vm.prank(attacker);
        vm.expectRevert();
        vault.allowVault(address(m), true);
    }

    function test_OwnerCanAlsoCallRebalance() public {
        _deposit(alice, THOUSAND);

        vm.prank(owner);
        vault.rebalance(address(morpho1));

        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);
    }

    function test_RevokedVaultBlocksRebalance() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(owner);
        vault.allowVault(address(morpho2), false);

        vm.prank(keeper);
        vm.expectRevert(UMYOVault.VaultNotAllowed.selector);
        vault.rebalance(address(morpho2));
    }

    // =========================================================================
    // Pause
    // =========================================================================

    function test_DepositRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), THOUSAND);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vault.deposit(THOUSAND, alice);
        vm.stopPrank();
    }

    function test_MintRevertsWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.startPrank(alice);
        usdc.approve(address(vault), THOUSAND);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vault.mint(THOUSAND * SHARE_SCALE, alice);
        vm.stopPrank();
    }

    function test_RebalanceRevertsWhenPaused() public {
        _deposit(alice, THOUSAND);

        vm.prank(owner);
        vault.pause();

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        vault.rebalance(address(morpho1));
    }

    function test_WithdrawWorksWhenPaused() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
    }

    function test_UnpauseRestoresDeposits() public {
        vm.startPrank(owner);
        vault.pause();
        vault.unpause();
        vm.stopPrank();

        assertGt(_deposit(alice, THOUSAND), 0);
    }

    // =========================================================================
    // ERC4626 compliance: maxDeposit / maxMint when paused
    // =========================================================================

    function test_MaxDepositZeroWhenPaused() public {
        assertEq(vault.maxDeposit(alice), type(uint256).max);

        vm.prank(owner);
        vault.pause();

        assertEq(vault.maxDeposit(alice), 0, "EIP-4626 s4.4 compliance");
    }

    function test_MaxMintZeroWhenPaused() public {
        assertEq(vault.maxMint(alice), type(uint256).max);

        vm.prank(owner);
        vault.pause();

        assertEq(vault.maxMint(alice), 0, "EIP-4626 s4.4 compliance");
    }

    // =========================================================================
    // maxWithdraw / maxRedeem
    // =========================================================================

    function test_MaxWithdrawEqualsEntitlement() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        assertApproxEqAbs(vault.maxWithdraw(alice), THOUSAND, 1);
    }

    function test_MaxWithdrawCappedByMorphoLiquidity() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();
        morpho1.simulateLoss(600 * ONE_USDC);

        assertApproxEqAbs(vault.maxWithdraw(alice), 400 * ONE_USDC, 1);
    }

    function test_MaxWithdrawIsHonoured() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        uint256 maxW = vault.maxWithdraw(alice);
        vm.prank(alice);
        vault.withdraw(maxW, alice, alice); // must not revert
    }

    function test_MaxRedeemIsHonoured() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        uint256 maxR = vault.maxRedeem(alice);
        vm.prank(alice);
        vault.redeem(maxR, alice, alice); // must not revert
    }

    // =========================================================================
    // Reward sweep
    // =========================================================================

    function test_SweepRewardsSendsToOwner() public {
        FakeUSDC reward = new FakeUSDC();
        reward.mint(address(vault), 500 * ONE_USDC);

        vm.prank(owner);
        vault.sweepRewards(address(reward));

        assertEq(reward.balanceOf(owner), 500 * ONE_USDC);
        assertEq(reward.balanceOf(address(vault)), 0);
    }

    function test_SweepRevertsOnUnderlying() public {
        vm.prank(owner);
        vm.expectRevert(UMYOVault.CannotSweepUnderlying.selector);
        vault.sweepRewards(address(usdc));
    }

    function test_SweepRevertsOnActiveVaultShares() public {
        _deposit(alice, THOUSAND);
        _deployToMorpho1();

        vm.prank(owner);
        vm.expectRevert(UMYOVault.CannotSweepUnderlying.selector);
        vault.sweepRewards(address(morpho1));
    }

    // =========================================================================
    // Mint
    // =========================================================================

    function test_MintSharesForUser() public {
        uint256 sharesToMint = THOUSAND * SHARE_SCALE;
        vm.startPrank(alice);
        usdc.approve(address(vault), THOUSAND);
        uint256 assetsSpent = vault.mint(sharesToMint, alice);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), sharesToMint);
        assertEq(assetsSpent, THOUSAND);
        assertEq(vault.totalAssets(), THOUSAND);
    }

    function test_MintRevertsWhenZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(UMYOVault.ZeroAddress.selector);
        vault.allowVault(address(0), true);
    }

    // =========================================================================
    // Claim rewards
    // =========================================================================

    function test_ClaimRewardsSendsTokensToVault() public {
        FakeUSDC rewardToken = new FakeUSDC();
        FakeDistributor distributor = new FakeDistributor();

        uint256 claimable = 100 * ONE_USDC;
        bytes32[] memory proof = new bytes32[](0);

        vm.prank(owner);
        vault.claimRewards(address(distributor), address(rewardToken), claimable, proof);

        assertEq(rewardToken.balanceOf(address(vault)), claimable);
    }

    function test_ClaimRewardsRevertsOnZeroDistributor() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(owner);
        vm.expectRevert(UMYOVault.ZeroAddress.selector);
        vault.claimRewards(address(0), address(usdc), 100, proof);
    }

    function test_ClaimRewardsOnlyOwner() public {
        FakeDistributor distributor = new FakeDistributor();
        bytes32[] memory proof = new bytes32[](0);
        vm.prank(attacker);
        vm.expectRevert();
        vault.claimRewards(address(distributor), address(usdc), 100, proof);
    }

    // =========================================================================
    // Inflation attack
    // =========================================================================

    function test_InflationAttackMitigated() public {
        // Attacker donates 1 USDC to empty vault (no shares minted).
        usdc.mint(attacker, ONE_USDC);
        vm.prank(attacker);
        usdc.transfer(address(vault), ONE_USDC);

        assertEq(vault.totalAssets(), ONE_USDC);
        assertEq(vault.totalSupply(), 0);

        // Victim deposits 1 USDC. _decimalsOffset=6 means shares are not rounded to 0.
        uint256 shares = _deposit(alice, ONE_USDC);
        assertGt(shares, 0, "victim must receive non-zero shares");

        // Victim can recover their full deposit.
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertApproxEqAbs(usdc.balanceOf(alice) - before, ONE_USDC, 1);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_EmptyVaultRebalanceSucceeds() public {
        // No deposits, keeper calls rebalance — deploys nothing, no revert.
        vm.prank(keeper);
        vault.rebalance(address(morpho1));

        assertEq(address(vault.morphoVault()), address(morpho1));
        assertEq(vault.totalAssets(), 0);
    }

    function test_TotalAssetsWithNoVault() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_TotalAssetsIdleOnly() public {
        usdc.mint(address(vault), THOUSAND);
        assertEq(vault.totalAssets(), THOUSAND);
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function testFuzz_DepositWithdrawRoundTrip(uint96 amount) public {
        vm.assume(amount >= ONE_USDC && amount <= TEN_THOUSAND);
        usdc.mint(alice, amount);
        uint256 before = usdc.balanceOf(alice);

        uint256 shares = _deposit(alice, amount);
        _deployToMorpho1();

        vm.prank(alice);
        vault.redeem(shares, alice, alice);

        assertApproxEqAbs(usdc.balanceOf(alice), before, 1, "no loss on round-trip");
        assertEq(vault.totalAssets(), 0);
    }

    function testFuzz_MultiDepositorFairShares(uint96 a, uint96 b) public {
        vm.assume(a >= ONE_USDC && a <= TEN_THOUSAND / 2);
        vm.assume(b >= ONE_USDC && b <= TEN_THOUSAND / 2);
        usdc.mint(alice, a);
        usdc.mint(bob,   b);

        _deposit(alice, a);
        _deposit(bob,   b);
        _deployToMorpho1();

        assertEq(vault.balanceOf(alice) + vault.balanceOf(bob), vault.totalSupply());

        // Cache balances before vm.prank — prank is consumed by the first call
        // including argument evaluation, so inline vault.balanceOf() would steal it.
        uint256 aliceShares = vault.balanceOf(alice);
        uint256 bobShares   = vault.balanceOf(bob);

        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        vm.prank(bob);
        vault.redeem(bobShares, bob, bob);

        assertApproxEqAbs(vault.totalAssets(), 0, 1);
    }

    // =========================================================================
    // Invariants
    // =========================================================================

    function testInvariant_YieldAccruesToDepositors() public {
        uint256 before = usdc.balanceOf(alice);

        _deposit(alice, THOUSAND);
        _deployToMorpho1();
        morpho1.simulateYield(50 * ONE_USDC);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertGe(usdc.balanceOf(alice), before + 50 * ONE_USDC - 2, "yield captured");
    }

    function testInvariant_TotalAssetsConsistency() public {
        _deposit(alice, THOUSAND);
        _deposit(bob,   2 * THOUSAND);
        _deployToMorpho1();

        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobAssets   = vault.convertToAssets(vault.balanceOf(bob));

        assertLe(
            aliceAssets + bobAssets,
            vault.totalAssets() + 2,
            "sum of claims must not exceed total assets"
        );
    }
}
