// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

/**
 * @title UMYOVault
 * @notice ERC4626 vault that routes USDC to the highest-yielding Morpho market.
 *
 * Strategy: single active Morpho vault at a time. All assets are deployed to one
 * target. Rebalancing is atomic — withdraw from old, switch target, deposit into new.
 *
 * Access model:
 *   - Owner: vault configuration, emergency recall, rebalancer assignment.
 *   - Rebalancer: time-sensitive operations (deploy, rebalance). Kept separate from
 *     owner so a keeper bot can act without holding full ownership keys.
 *
 * Security notes:
 *   - nonReentrant on all user-facing state-changing paths.
 *   - SafeERC20.forceApprove for exact-amount approvals (handles USDC's non-standard
 *     approve behavior that requires zeroing before setting a new value).
 *   - No infinite approvals: each deposit call sets the exact approval needed.
 *   - redeem() is overridden alongside withdraw() so BOTH paths trigger Morpho recall.
 *     Omitting this override was a critical bug — base redeem() would revert silently
 *     if assets are deployed.
 */
contract UMYOVault is ERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    IERC4626 public morphoVault;
    address public rebalancer;

    // =========================================================================
    // Events — structured for The Graph / Dune indexing
    // =========================================================================

    /// @notice Active Morpho target changed (initial set or mid-rebalance)
    event MorphoVaultUpdated(address indexed oldVault, address indexed newVault);

    /// @notice Full rebalance cycle completed atomically
    event Rebalanced(
        address indexed oldVault,
        address indexed newVault,
        uint256 assetsWithdrawn,
        uint256 assetsDeployed,
        uint256 timestamp
    );

    /// @notice Idle assets sent to the active Morpho vault
    event AssetsDeployed(address indexed vault, uint256 assets);

    /// @notice Assets recalled from Morpho back to this contract
    event AssetsRecalled(address indexed vault, uint256 assets);

    /// @notice Keeper address changed
    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error VaultNotSet();
    error SameVault();
    error SlippageExceeded(uint256 received, uint256 minimum);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error Unauthorized();

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Owner can always act as rebalancer — avoids lockout if keeper key is lost.
    modifier onlyRebalancer() {
        if (msg.sender != rebalancer && msg.sender != owner()) revert Unauthorized();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param _asset Underlying ERC20 (USDC)
     * @param _owner Initial owner. Separate from msg.sender to support CREATE2 deployments.
     */
    constructor(IERC20 _asset, address _owner)
        ERC4626(_asset)
        ERC20("USDC Morpho Yield Optimizer", "vUMYO")
        Ownable(_owner)
    {}

    // =========================================================================
    // Admin
    // =========================================================================

    /**
     * @notice Set the active Morpho vault without moving funds.
     * @dev Use only for initial configuration. Use rebalance() to migrate live funds.
     */
    function setMorphoVault(IERC4626 vault) external onlyOwner {
        if (address(vault) == address(0)) revert ZeroAddress();
        address old = address(morphoVault);
        morphoVault = vault;
        emit MorphoVaultUpdated(old, address(vault));
    }

    /**
     * @notice Assign the keeper that can trigger rebalances and deployments.
     */
    function setRebalancer(address _rebalancer) external onlyOwner {
        if (_rebalancer == address(0)) revert ZeroAddress();
        address old = rebalancer;
        rebalancer = _rebalancer;
        emit RebalancerUpdated(old, _rebalancer);
    }

    /**
     * @notice Emergency: pull all capital from Morpho back to this contract.
     * @dev Leaves assets idle. Use deployToMorpho() or rebalance() to redeploy.
     */
    function recallFromMorpho() external onlyOwner {
        IERC4626 _morpho = morphoVault;
        if (address(_morpho) == address(0)) revert VaultNotSet();
        uint256 shares = _morpho.balanceOf(address(this));
        if (shares == 0) return;
        uint256 assets = _morpho.redeem(shares, address(this), address(this));
        emit AssetsRecalled(address(_morpho), assets);
    }

    // =========================================================================
    // Strategy Management
    // =========================================================================

    /**
     * @notice Deploy all idle assets in this contract to the active Morpho vault.
     * @dev No-op if nothing to deploy or vault not set.
     */
    function deployToMorpho() external onlyRebalancer {
        IERC4626 _morpho = morphoVault;
        if (address(_morpho) == address(0)) revert VaultNotSet();
        uint256 assets = IERC20(asset()).balanceOf(address(this));
        if (assets == 0) return;
        _deployToMorpho(_morpho, assets);
    }

    /**
     * @notice Atomically migrate all assets to a better-yielding Morpho vault.
     *
     * Execution order:
     *   1. Recall all from old vault (if any shares held)
     *   2. Switch morphoVault pointer to newVault
     *   3. Deploy all local assets to newVault
     *
     * The minAssetsReceived guard prevents sandwich attacks on step 1. Pass 0 to
     * skip the check (e.g. when migrating from a vault with no active position).
     *
     * @param newVault  Target Morpho vault (ERC4626-compatible)
     * @param minAssetsReceived  Slippage floor on the recall step
     */
    function rebalance(address newVault, uint256 minAssetsReceived) external onlyRebalancer {
        if (newVault == address(0)) revert ZeroAddress();
        if (newVault == address(morphoVault)) revert SameVault();

        address oldVault = address(morphoVault);
        uint256 assetsRecalled;

        if (oldVault != address(0)) {
            uint256 shares = IERC4626(oldVault).balanceOf(address(this));
            if (shares > 0) {
                assetsRecalled = IERC4626(oldVault).redeem(shares, address(this), address(this));
                if (assetsRecalled < minAssetsReceived) {
                    revert SlippageExceeded(assetsRecalled, minAssetsReceived);
                }
                emit AssetsRecalled(oldVault, assetsRecalled);
            }
        }

        morphoVault = IERC4626(newVault);
        emit MorphoVaultUpdated(oldVault, newVault);

        uint256 localAssets = IERC20(asset()).balanceOf(address(this));
        if (localAssets > 0) {
            _deployToMorpho(IERC4626(newVault), localAssets);
        }

        emit Rebalanced(oldVault, newVault, assetsRecalled, localAssets, block.timestamp);
    }

    // =========================================================================
    // ERC4626 Overrides
    // =========================================================================

    /**
     * @notice Total assets: idle balance + value of deployed Morpho position.
     * @dev convertToAssets is semantically correct here (not previewRedeem, which
     *      applies rounding favoring the vault and can be slightly lower).
     */
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        IERC4626 _morpho = morphoVault;
        uint256 deployed = address(_morpho) != address(0)
            ? _morpho.convertToAssets(_morpho.balanceOf(address(this)))
            : 0;
        return idle + deployed;
    }

    /**
     * @notice EIP-4626: max assets owner can withdraw right now, capped by liquidity.
     * @dev MUST NOT return more than what withdraw() would actually accept without revert.
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(convertToAssets(balanceOf(owner)), _availableLiquidity());
    }

    /**
     * @notice EIP-4626: max shares owner can redeem right now, capped by liquidity.
     * @dev When liquidity covers the full user position, return their entire balance.
     *      Naively converting availableLiquidity→shares (floor) would return totalSupply-1
     *      when exchange rate > 1 and all assets are local — incorrectly blocking full redemption.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 userShares = balanceOf(owner);
        uint256 userAssets = convertToAssets(userShares);
        uint256 liquidity  = _availableLiquidity();
        if (liquidity >= userAssets) return userShares;
        return convertToShares(liquidity);
    }

    /**
     * @notice Deposit assets and mint shares.
     */
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        shares = super.deposit(assets, receiver);
    }

    /**
     * @notice Mint exact shares by depositing the required assets.
     */
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = super.mint(shares, receiver);
    }

    /**
     * @notice Withdraw exact assets by burning shares.
     * @dev Recalls from Morpho if local balance is insufficient.
     */
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _ensureLocalLiquidity(assets);
        shares = super.withdraw(assets, receiver, owner);
    }

    /**
     * @notice Burn exact shares to receive assets.
     * @dev Recalls from Morpho if local balance is insufficient.
     *      previewRedeem is evaluated before the recall so the liquidity check
     *      matches the exact amount super.redeem will transfer.
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _ensureLocalLiquidity(previewRedeem(shares));
        assets = super.redeem(shares, receiver, owner);
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /**
     * @notice Pull enough assets from Morpho so this contract holds at least `assets` locally.
     */
    function _ensureLocalLiquidity(uint256 assets) internal {
        uint256 local = IERC20(asset()).balanceOf(address(this));
        if (local >= assets) return;

        uint256 deficit = assets - local;
        IERC4626 _morpho = morphoVault;
        if (address(_morpho) == address(0)) revert InsufficientLiquidity(assets, local);

        uint256 available = _morpho.maxWithdraw(address(this));
        if (deficit > available) revert InsufficientLiquidity(assets, local + available);

        // ERC4626 withdraw() guarantees exactly `deficit` assets reach the receiver
        _morpho.withdraw(deficit, address(this), address(this));
        emit AssetsRecalled(address(_morpho), deficit);
    }

    /**
     * @notice Total assets immediately withdrawable: local balance + Morpho maxWithdraw.
     */
    function _availableLiquidity() internal view returns (uint256) {
        uint256 local = IERC20(asset()).balanceOf(address(this));
        IERC4626 _morpho = morphoVault;
        uint256 fromMorpho = address(_morpho) != address(0)
            ? _morpho.maxWithdraw(address(this))
            : 0;
        return local + fromMorpho;
    }

    /**
     * @notice Approve `vault` for exactly `assets` and deposit.
     * @dev forceApprove handles USDC's non-standard two-step approval (set 0 then set value).
     */
    function _deployToMorpho(IERC4626 vault, uint256 assets) internal {
        IERC20(asset()).forceApprove(address(vault), assets);
        vault.deposit(assets, address(this));
        emit AssetsDeployed(address(vault), assets);
    }
}
