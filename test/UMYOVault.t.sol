// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {UMYOVault} from "../contracts/UMYOVault.sol";
import {FakeMorpho} from "../contracts/FakeMorpho.sol";
import {FakeUSDC} from "../contracts/FakeUSDC.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

contract UMYOVaultTest is Test {
    UMYOVault  vault;
    FakeMorpho morpho1;
    FakeMorpho morpho2;
    FakeUSDC   usdc;

    address owner     = makeAddr("owner");
    address keeper    = makeAddr("keeper");
    address alice     = makeAddr("alice");
    address bob       = makeAddr("bob");
    address attacker  = makeAddr("attacker");

    uint256 constant ONE_USDC    = 1e6;
    uint256 constant THOUSAND    = 1_000 * ONE_USDC;
    uint256 constant TEN_THOUSAND = 10_000 * ONE_USDC;

    // =========================================================================
    // Setup
    // =========================================================================

    function setUp() public {
        usdc    = new FakeUSDC();
        morpho1 = new FakeMorpho(IERC20(address(usdc)));
        morpho2 = new FakeMorpho(IERC20(address(usdc)));
        vault   = new UMYOVault(IERC20(address(usdc)), owner);

        vm.startPrank(owner);
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
        vault.deployToMorpho();
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

    function test_DepositMintsSharesOneToOne() public {
        uint256 shares = _deposit(alice, THOUSAND);
        assertEq(shares, THOUSAND, "1:1 share minting at empty vault");
        assertEq(vault.balanceOf(alice), THOUSAND);
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
        // vault now has 1100 USDC worth of assets, 1000 shares outstanding
        // Bob deposits 1100 USDC → should get 1000 shares (1:1 in asset terms)
        _deposit(bob, 1_100 * ONE_USDC);

        // alice: 1000 shares worth ~1100 USDC; bob: ~1000 shares worth ~1100 USDC
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(alice)), 1_100 * ONE_USDC, 2);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(bob)),   1_100 * ONE_USDC, 2);
    }

    // =========================================================================
    // Withdraw
    // =========================================================================

    function test_WithdrawLocal() public {
        _deposit(alice, THOUSAND);
        // Assets are idle (not deployed) — withdraw should work without touching Morpho
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

        // alice's shares are worth 1100 USDC now
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
        // Simulate 500 USDC loss from Morpho (only ~500 USDC left)
        morpho1.simulateLoss(500 * ONE_USDC);

        // alice tries to withdraw 1000 USDC but only 500 is available
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
        vault.rebalance(address(morpho2), THOUSAND - 1);

        assertEq(usdc.balanceOf(address(morpho1)), 0, "old vault drained");
        assertEq(usdc.balanceOf(address(morpho2)), THOUSAND, "new vault funded");
        assertEq(address(vault.morphoVault()), address(morpho2));
        assertEq(vault.totalAssets(), THOUSAND);
    }

    function test_RebalanceFromNoVault() public {
        // Deploy a fresh vault with no Morpho target set yet
        UMYOVault freshVault = new UMYOVault(IERC20(address(usdc)), owner);
        usdc.mint(address(freshVault), THOUSAND); // seed with idle USDC

        vm.startPrank(owner);
        freshVault.setRebalancer(keeper);
        vm.stopPrank();

        // Rebalance with oldVault == address(0): skip recall, deploy to morpho1
        vm.prank(keeper);
        freshVault.rebalance(address(morpho1), 0);

        assertEq(usdc.balanceOf(address(morpho1)), THOUSAND);
        assertEq(address(freshVault.morphoVault()), address(morpho1));
    }

    function test_RebalanceSlippageProtection() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        // Simulate 20% loss in morpho1 before rebalance (~800 USDC returned)
        morpho1.simulateLoss(200 * ONE_USDC);

        // minAssetsReceived = 900 USDC but only 800 will come back → should revert
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(UMYOVault.SlippageExceeded.selector, 800 * ONE_USDC, 900 * ONE_USDC));
        vault.rebalance(address(morpho2), 900 * ONE_USDC);

        // Funds are still in morpho1 (state fully rolled back)
        assertEq(usdc.balanceOf(address(morpho1)), 800 * ONE_USDC);
    }

    function test_RebalanceSameVaultReverts() public {
        vm.prank(keeper);
        vm.expectRevert(UMYOVault.SameVault.selector);
        vault.rebalance(address(morpho1), 0);
    }

    function test_RebalanceZeroAddressReverts() public {
        vm.prank(keeper);
        vm.expectRevert(UMYOVault.ZeroAddress.selector);
        vault.rebalance(address(0), 0);
    }

    function test_UserCanWithdrawAfterRebalance() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(keeper);
        vault.rebalance(address(morpho2), 0);

        vm.prank(alice);
        vault.withdraw(THOUSAND, alice, alice);

        assertEq(usdc.balanceOf(alice), TEN_THOUSAND);
    }

    // =========================================================================
    // Access control
    // =========================================================================

    function test_OnlyOwnerCanSetMorphoVault() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setMorphoVault(IERC4626(address(morpho2)));
    }

    function test_OnlyOwnerCanSetRebalancer() public {
        vm.prank(attacker);
        vm.expectRevert();
        vault.setRebalancer(attacker);
    }

    function test_OnlyOwnerCanRecall() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        vault.recallFromMorpho();
    }

    function test_OnlyRebalancerOrOwnerCanDeploy() public {
        _deposit(alice, THOUSAND);

        vm.prank(attacker);
        vm.expectRevert(UMYOVault.Unauthorized.selector);
        vault.deployToMorpho();

        // keeper can deploy
        vm.prank(keeper);
        vault.deployToMorpho();
    }

    function test_OwnerCanAlsoRebalance() public {
        _deposit(alice, THOUSAND);
        _deployAll();

        vm.prank(owner);
        vault.rebalance(address(morpho2), 0);

        assertEq(address(vault.morphoVault()), address(morpho2));
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
        vault.deployToMorpho();

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
        morpho1.simulateLoss(600 * ONE_USDC); // only 400 left

        uint256 maxW = vault.maxWithdraw(alice);
        assertApproxEqAbs(maxW, 400 * ONE_USDC, 1);
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

        // After deposit+deploy+redeem, alice should have her original balance back
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

        // After both redeem, vault is empty and both get their proportional share
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
    // Invariant test
    // =========================================================================

    /**
     * @notice The vault's share price must never decrease without a real loss.
     *         After a round-trip deposit→deploy→redeem with no yield, the user
     *         receives at least assets - 1 (rounding tolerance).
     */
    function testInvariant_SharePriceMonotonicallyIncreases() public {
        uint256 before = usdc.balanceOf(alice);

        _deposit(alice, THOUSAND);
        _deployAll();

        // Simulate 5% yield
        morpho1.simulateYield(50 * ONE_USDC);

        uint256 aliceShares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.redeem(aliceShares, alice, alice);

        assertGe(usdc.balanceOf(alice), before + 50 * ONE_USDC - 2, "yield captured");
    }

    /**
     * @notice sum(convertToAssets(shares_i)) must never exceed totalAssets() + rounding.
     *         With a single depositor this simplifies to the identity check.
     */
    function testInvariant_TotalAssetsConsistency() public {
        _deposit(alice, THOUSAND);
        _deposit(bob,   2 * THOUSAND);
        _deployAll();

        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        uint256 bobAssets   = vault.convertToAssets(vault.balanceOf(bob));

        assertLe(
            aliceAssets + bobAssets,
            vault.totalAssets() + 2,  // 2 units max rounding across two conversions
            "sum of claims must not exceed vault holdings"
        );
    }
}
