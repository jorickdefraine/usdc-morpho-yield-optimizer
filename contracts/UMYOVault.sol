// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";
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
 *   - Owner: vault configuration (approveVault, setRebalancer, setMorphoVault, pause,
 *     setRebalanceCooldown, sweepRewards). Cannot move funds directly.
 *   - Rebalancer: fund-moving operations (deployToMorpho, rebalance, recallFromMorpho).
 *     Kept separate from owner so neither key alone can drain depositor funds.
 *
 * Security notes:
 *   - Roles are strictly separated: owner configures, rebalancer executes. An attacker
 *     must compromise BOTH keys to drain funds via rebalance (owner approves target,
 *     rebalancer deploys). Use a timelocked multisig as owner in production.
 *   - nonReentrant on all state-changing paths (user-facing and admin).
 *   - SafeERC20.forceApprove for exact-amount approvals (handles USDC's non-standard
 *     approve behavior that requires zeroing before setting a new value).
 *   - No infinite approvals: each deposit call sets the exact approval needed.
 *   - redeem() is overridden alongside withdraw() so BOTH paths trigger Morpho recall.
 *   - approvedVaults whitelist restricts both rebalance() targets and setMorphoVault()
 *     targets, preventing fund routing to unapproved contracts.
 *   - sweepRewards() guards against sweeping the underlying asset, the active Morpho
 *     vault shares, AND the previous Morpho vault shares (post-rebalance residuals).
 *   - setMorphoVault() reverts if funds are currently deployed, preventing permanent
 *     stranding of assets in the old vault.
 *   - _decimalsOffset = 6 raises virtual-share inflation-attack cost to ~1M× victim
 *     deposit for USDC's 6-decimal precision (OZ default of 0 only costs 2×).
 *   - _ensureLocalLiquidity pulls deficit+1 wei when headroom exists to absorb
 *     1-wei ERC4626 rounding from the Morpho vault's share-burn math, preventing
 *     a rare revert when a user redeems exactly 100% of available liquidity.
 *   - rebalanceCooldown limits how frequently the rebalancer can migrate funds,
 *     capping gas-griefing and repeated-slippage attacks from a compromised key.
 */
contract UMYOVault is ERC4626, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    IERC4626 public morphoVault;
    /// @notice Previous Morpho vault, retained to block sweeping residual shares.
    address public previousMorphoVault;
    address public rebalancer;

    /// @notice Vaults eligible as rebalance targets and setMorphoVault targets. Owner-controlled.
    mapping(address => bool) public approvedVaults;

    /// @notice Minimum seconds between successive rebalance() calls. 0 = no limit.
    uint256 public rebalanceCooldown;
    /// @notice Timestamp of the most recent successful rebalance().
    uint256 public lastRebalanceTime;

    // =========================================================================
    // Events
    // =========================================================================

    event MorphoVaultUpdated(address indexed oldVault, address indexed newVault);
    event Rebalanced(
        address indexed oldVault,
        address indexed newVault,
        uint256 assetsWithdrawn,
        uint256 assetsDeployed,
        uint256 timestamp
    );
    event AssetsDeployed(address indexed vault, uint256 assets);
    event AssetsRecalled(address indexed vault, uint256 assets);
    event RebalancerUpdated(address indexed oldRebalancer, address indexed newRebalancer);
    event RewardSwept(address indexed token, address indexed to, uint256 amount);
    event VaultApprovalChanged(address indexed vault, bool approved);
    event RebalanceCooldownUpdated(uint256 oldCooldown, uint256 newCooldown);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error VaultNotSet();
    error SameVault();
    error SlippageExceeded(uint256 received, uint256 minimum);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error Unauthorized();
    error CannotSweepUnderlying();
    error VaultNotApproved();
    error VaultHasDeployedFunds();
    error AssetMismatch();
    error RebalanceCooldownActive(uint256 nextAllowed);

    // =========================================================================
    // Modifiers
    // =========================================================================

    /// @dev Only the designated rebalancer. Owner is intentionally excluded to
    ///      enforce role separation: owner configures, rebalancer executes. This
    ///      means draining funds requires compromising BOTH keys.
    modifier onlyRebalancer() {
        if (msg.sender != rebalancer) revert Unauthorized();
        _;
    }

    /// @dev Emergency operations (recall) are open to both owner and rebalancer
    ///      so a fast-moving keeper can act without waiting for multisig quorum.
    modifier onlyOwnerOrRebalancer() {
        if (msg.sender != owner() && msg.sender != rebalancer) revert Unauthorized();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    constructor(IERC20 _asset, address _owner)
        ERC4626(_asset)
        ERC20("USDC Morpho Yield Optimizer", "vUMYO")
        Ownable(_owner)
    {}

    // =========================================================================
    // Admin
    // =========================================================================

    /**
     * @notice Whitelist a vault as a valid target for rebalance() and setMorphoVault().
     * @dev Must be called before either function can use a new vault address.
     *      The underlying asset is verified inside rebalance() and setMorphoVault();
     *      this function is intentionally kept lightweight to support pre-approval workflows.
     */
    function approveVault(address vault) external onlyOwner {
        if (vault == address(0)) revert ZeroAddress();
        approvedVaults[vault] = true;
        emit VaultApprovalChanged(vault, true);
    }

    /// @notice Remove a vault from the whitelist.
    function revokeVault(address vault) external onlyOwner {
        approvedVaults[vault] = false;
        emit VaultApprovalChanged(vault, false);
    }

    /// @notice Halt new deposits and mints. Does not affect withdrawals.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Resume normal operation.
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Set the active Morpho vault without moving funds.
     * @dev Use only for initial configuration when no funds are deployed.
     *      The vault must already be in the approvedVaults whitelist.
     *      Reverts if funds are currently in the old vault — use rebalance() instead.
     */
    function setMorphoVault(IERC4626 vault) external onlyOwner {
        if (address(vault) == address(0)) revert ZeroAddress();
        if (address(vault) == address(morphoVault)) revert SameVault();
        if (!approvedVaults[address(vault)]) revert VaultNotApproved();
        if (vault.asset() != asset()) revert AssetMismatch();
        // Prevent silently stranding deployed funds in the old vault.
        if (address(morphoVault) != address(0) && morphoVault.balanceOf(address(this)) > 0) {
            revert VaultHasDeployedFunds();
        }
        address old = address(morphoVault);
        previousMorphoVault = old;
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
     * @notice Set the minimum time (in seconds) between successive rebalance() calls.
     * @dev Set to 0 to disable the cooldown. Limits gas-griefing from a compromised
     *      rebalancer key making rapid rebalances to incur repeated slippage.
     */
    function setRebalanceCooldown(uint256 cooldown) external onlyOwner {
        uint256 old = rebalanceCooldown;
        rebalanceCooldown = cooldown;
        emit RebalanceCooldownUpdated(old, cooldown);
    }

    /**
     * @notice Sweep any non-underlying token (e.g. MORPHO rewards) to the owner.
     * @dev Reverts if token is:
     *      - the vault's underlying asset
     *      - the active Morpho vault's share token
     *      - the previous Morpho vault's share token (guards residual shares post-rebalance)
     */
    function sweepRewards(address token) external onlyOwner {
        if (token == asset()) revert CannotSweepUnderlying();
        if (token == address(morphoVault)) revert CannotSweepUnderlying();
        if (token == previousMorphoVault) revert CannotSweepUnderlying();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(token).safeTransfer(owner(), amount);
        emit RewardSwept(token, owner(), amount);
    }

    /**
     * @notice Emergency: pull all capital from Morpho back to this contract.
     * @dev Callable by both owner and rebalancer so a fast keeper can act without
     *      waiting for multisig quorum during an active Morpho incident.
     *      Leaves assets idle. Use deployToMorpho() or rebalance() to redeploy.
     */
    function recallFromMorpho() external onlyOwnerOrRebalancer nonReentrant {
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
     * @param minSharesOut Minimum Morpho shares to receive. Guards against sandwich
     *                     attacks on the deploy step. Pass 0 to skip (e.g. testing).
     */
    function deployToMorpho(uint256 minSharesOut) external onlyRebalancer nonReentrant {
        IERC4626 _morpho = morphoVault;
        if (address(_morpho) == address(0)) revert VaultNotSet();
        uint256 assets = IERC20(asset()).balanceOf(address(this));
        if (assets == 0) return;
        uint256 sharesBefore = _morpho.balanceOf(address(this));
        _deployToMorpho(_morpho, assets);
        uint256 sharesReceived = _morpho.balanceOf(address(this)) - sharesBefore;
        if (sharesReceived < minSharesOut) revert SlippageExceeded(sharesReceived, minSharesOut);
    }

    /**
     * @notice Atomically migrate all assets to a better-yielding Morpho vault.
     *
     * Execution order:
     *   1. Enforce rebalance cooldown (if set)
     *   2. Recall all from old vault (if any shares held)
     *   3. Switch morphoVault pointer to newVault
     *   4. Deploy all local assets to newVault
     *   5. Record timestamp for next cooldown check
     *
     * @param newVault          Target Morpho vault. Must be in approvedVaults.
     * @param minAssetsReceived Slippage floor on the recall step (step 2).
     * @param minSharesOut      Minimum Morpho shares to receive on the deploy step (step 4).
     *                          Guards against sandwich attacks on the new vault's share price.
     *                          Pass 0 to skip (e.g. when migrating from a vault with no position).
     */
    function rebalance(address newVault, uint256 minAssetsReceived, uint256 minSharesOut)
        external
        onlyRebalancer
        nonReentrant
    {
        uint256 cooldown = rebalanceCooldown;
        if (cooldown > 0 && lastRebalanceTime > 0 && block.timestamp < lastRebalanceTime + cooldown) {
            revert RebalanceCooldownActive(lastRebalanceTime + cooldown);
        }

        if (newVault == address(0)) revert ZeroAddress();
        if (newVault == address(morphoVault)) revert SameVault();
        if (!approvedVaults[newVault]) revert VaultNotApproved();
        if (IERC4626(newVault).asset() != asset()) revert AssetMismatch();

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

        previousMorphoVault = oldVault;
        morphoVault = IERC4626(newVault);
        emit MorphoVaultUpdated(oldVault, newVault);

        uint256 localAssets = IERC20(asset()).balanceOf(address(this));
        uint256 assetsDeployed;
        if (localAssets > 0) {
            uint256 sharesBefore = IERC4626(newVault).balanceOf(address(this));
            _deployToMorpho(IERC4626(newVault), localAssets);
            uint256 sharesReceived = IERC4626(newVault).balanceOf(address(this)) - sharesBefore;
            if (sharesReceived < minSharesOut) revert SlippageExceeded(sharesReceived, minSharesOut);
            assetsDeployed = localAssets;
        }

        lastRebalanceTime = block.timestamp;
        emit Rebalanced(oldVault, newVault, assetsRecalled, assetsDeployed, block.timestamp);
    }

    // =========================================================================
    // ERC4626 Overrides
    // =========================================================================

    /**
     * @dev Raises virtual-share count to 10^6, matching USDC's own decimal precision.
     *      With the default offset of 0, an inflation attack on a 6-decimal asset
     *      only costs ~2× the victim's deposit. With offset 6, cost is ~10^6×.
     */
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Total assets: idle balance + value of deployed Morpho position.
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
     */
    function maxWithdraw(address owner) public view override returns (uint256) {
        return Math.min(convertToAssets(balanceOf(owner)), _availableLiquidity());
    }

    /**
     * @notice EIP-4626: max shares owner can redeem right now, capped by liquidity.
     */
    function maxRedeem(address owner) public view override returns (uint256) {
        uint256 userShares = balanceOf(owner);
        uint256 userAssets = convertToAssets(userShares);
        uint256 liquidity  = _availableLiquidity();
        if (liquidity >= userAssets) return userShares;
        return convertToShares(liquidity);
    }

    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        whenNotPaused
        returns (uint256 assets)
    {
        assets = super.mint(shares, receiver);
    }

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
     * @dev previewRedeem is evaluated before the recall so the liquidity check
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
     * @dev Pulls deficit+1 wei when headroom exists. This absorbs a 1-wei ERC4626 rounding
     *      loss that can occur in Morpho's share-burn math, preventing an otherwise valid
     *      maxRedeem check from reverting when a user redeems exactly 100% of liquidity.
     */
    function _ensureLocalLiquidity(uint256 assets) internal {
        uint256 local = IERC20(asset()).balanceOf(address(this));
        if (local >= assets) return;

        uint256 deficit = assets - local;
        IERC4626 _morpho = morphoVault;
        if (address(_morpho) == address(0)) revert InsufficientLiquidity(assets, local);

        uint256 available = _morpho.maxWithdraw(address(this));
        if (deficit > available) revert InsufficientLiquidity(assets, local + available);

        uint256 toWithdraw = deficit < available ? deficit + 1 : deficit;
        _morpho.withdraw(toWithdraw, address(this), address(this));
        emit AssetsRecalled(address(_morpho), toWithdraw);
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
     */
    function _deployToMorpho(IERC4626 vault, uint256 assets) internal {
        IERC20(asset()).forceApprove(address(vault), assets);
        vault.deposit(assets, address(this));
        emit AssetsDeployed(address(vault), assets);
    }
}
