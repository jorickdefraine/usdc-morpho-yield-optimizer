// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";

interface IRewardsDistributor {
    function claim(address account, address reward, uint256 claimable, bytes32[] calldata proof) external;
}

/**
 * @title UMYOVault
 * @notice ERC4626 vault that routes USDC to the highest-yielding Morpho vault.
 *
 * Roles:
 *   - Owner  : manage vault whitelist, set keeper, emergency actions, pause
 *   - Keeper : call rebalance() — also callable by owner for emergency migrations
 *
 * Security:
 *   - Vault whitelist prevents a compromised keeper from routing to arbitrary contracts
 *   - nonReentrant on all state-changing paths
 *   - Ownable2Step prevents accidental ownership loss
 *   - _decimalsOffset = 6 raises inflation-attack cost to ~10^6x on USDC
 *   - maxDeposit/maxMint return 0 when paused (EIP-4626 s4.4)
 *   - Strict CEI in rebalance(): state updated before all external calls
 *   - forceApprove handles USDC's non-standard approve return value
 */
contract UMYOVault is ERC4626, Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =========================================================================
    // State
    // =========================================================================

    string public constant VERSION = "1.2.0";

    IERC4626 public morphoVault;
    address  public immutable keeper;

    /// @notice Morpho vaults approved as rebalance targets. Owner-managed.
    mapping(address => bool) public allowedVaults;

    // =========================================================================
    // Events
    // =========================================================================

    event Rebalanced(address indexed fromVault, address indexed toVault, uint256 assetsDeployed);
    event VaultAllowanceChanged(address indexed vault, bool allowed);
    event AssetsRecalled(address indexed vault, uint256 assets);
    event AssetsDeployed(address indexed vault, uint256 assets);
    event RewardSwept(address indexed token, address indexed to, uint256 amount);

    // =========================================================================
    // Errors
    // =========================================================================

    error ZeroAddress();
    error Unauthorized();
    error VaultNotAllowed();
    error AssetMismatch();
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error CannotSweepUnderlying();

    // =========================================================================
    // Modifier
    // =========================================================================

    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) revert Unauthorized();
        _;
    }

    // =========================================================================
    // Constructor
    // =========================================================================

    /**
     * @param _asset   Underlying token (USDC on Base).
     * @param _owner   Initial owner — should be a multisig.
     * @param _keeper  Keeper EOA authorised to call rebalance().
     */
    constructor(IERC20 _asset, address _owner, address _keeper)
        ERC4626(_asset)
        ERC20("USDC Morpho Yield Optimizer", "vUMYO")
        Ownable(_owner)
    {
        if (_keeper == address(0)) revert ZeroAddress();
        keeper = _keeper;
    }

    // =========================================================================
    // Owner — configuration
    // =========================================================================

    /// @notice Add or remove a Morpho vault from the approved targets.
    function allowVault(address vault_, bool allowed) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        allowedVaults[vault_] = allowed;
        emit VaultAllowanceChanged(vault_, allowed);
    }

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /**
     * @notice Pull ALL funds from the active Morpho vault back to idle.
     * @dev Use during Morpho incidents. Does not pause — call pause() separately if needed.
     *      Callable even when paused so the owner can always retrieve funds.
     */
    function emergencyWithdraw() external onlyOwner nonReentrant {
        IERC4626 vault_ = morphoVault;
        if (address(vault_) == address(0)) return;
        uint256 shares = vault_.balanceOf(address(this));
        if (shares == 0) return;
        uint256 assets = vault_.redeem(shares, address(this), address(this));
        emit AssetsRecalled(address(vault_), assets);
    }

    /**
     * @notice Claim rewards from a Morpho Universal Rewards Distributor.
     * @dev The vault holds Morpho vault shares in its own name, so it is the eligible
     *      claimant — not individual depositors. After claiming, call sweepRewards()
     *      to forward the tokens to the owner.
     */
    function claimRewards(
        address distributor,
        address rewardToken,
        uint256 claimable,
        bytes32[] calldata proof
    ) external onlyOwner {
        if (distributor == address(0)) revert ZeroAddress();
        IRewardsDistributor(distributor).claim(address(this), rewardToken, claimable, proof);
    }

    /**
     * @notice Sweep ERC20 reward tokens (e.g. MORPHO incentives) to the owner.
     * @dev Reverts for the underlying asset or active vault shares.
     */
    function sweepRewards(address token) external onlyOwner {
        if (token == asset() || token == address(morphoVault)) revert CannotSweepUnderlying();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) return;
        IERC20(token).safeTransfer(owner(), amount);
        emit RewardSwept(token, owner(), amount);
    }

    // =========================================================================
    // Keeper — rebalance
    // =========================================================================

    /**
     * @notice Migrate all funds to newVault, or redeploy idle USDC to the current vault.
     *
     * Steps (strict CEI):
     *   1. Validate: whitelist, asset match
     *   2. Effects  : update morphoVault
     *   3. Interactions:
     *        a. Recall ALL shares from old vault (skipped if same-vault call)
     *        b. Deploy ALL idle USDC to new vault
     *
     * Passing the current vault address re-deploys any new idle USDC without migrating.
     * This is how the keeper deploys fresh deposits between vault changes.
     *
     * @param newVault Must be in allowedVaults and share the same underlying asset.
     */
    function rebalance(address newVault) external onlyKeeperOrOwner nonReentrant whenNotPaused {
        if (newVault == address(0)) revert ZeroAddress();
        if (!allowedVaults[newVault]) revert VaultNotAllowed();
        if (IERC4626(newVault).asset() != asset()) revert AssetMismatch();

        address oldVault = address(morphoVault);

        // ── Effects ─────────────────────────────────────────────────────────
        morphoVault = IERC4626(newVault);

        // ── Interactions ─────────────────────────────────────────────────────
        // Recall from old vault only when migrating to a different vault.
        if (oldVault != address(0) && oldVault != newVault) {
            uint256 shares = IERC4626(oldVault).balanceOf(address(this));
            if (shares > 0) {
                uint256 recalled = IERC4626(oldVault).redeem(shares, address(this), address(this));
                emit AssetsRecalled(oldVault, recalled);
            }
        }

        // Deploy all idle USDC to the (possibly new) vault.
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle > 0) {
            IERC20(asset()).forceApprove(newVault, idle);
            IERC4626(newVault).deposit(idle, address(this));
            emit AssetsDeployed(newVault, idle);
        }

        emit Rebalanced(oldVault, newVault, idle);
    }

    // =========================================================================
    // ERC4626 Overrides
    // =========================================================================

    /// @dev Offset of 6 matches USDC's decimals, raising the inflation-attack cost to ~10^6x.
    function _decimalsOffset() internal pure override returns (uint8) { return 6; }

    /// @notice EIP-4626 s4.4: MUST return 0 when deposits are not permitted.
    function maxDeposit(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxDeposit(receiver);
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return paused() ? 0 : super.maxMint(receiver);
    }

    /// @notice Idle USDC + fair value of the Morpho vault position.
    function totalAssets() public view override returns (uint256) {
        IERC4626 vault_ = morphoVault;
        uint256 deployed = address(vault_) != address(0)
            ? vault_.convertToAssets(vault_.balanceOf(address(this)))
            : 0;
        return IERC20(asset()).balanceOf(address(this)) + deployed;
    }

    /// @notice Capped by currently withdrawable liquidity from Morpho.
    function maxWithdraw(address _owner) public view override returns (uint256) {
        return Math.min(convertToAssets(balanceOf(_owner)), _availableLiquidity());
    }

    function maxRedeem(address _owner) public view override returns (uint256) {
        uint256 userShares = balanceOf(_owner);
        uint256 userAssets = convertToAssets(userShares);
        uint256 liquidity  = _availableLiquidity();
        if (liquidity >= userAssets) return userShares;
        return convertToShares(liquidity);
    }

    function deposit(uint256 assets, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver)
        public override nonReentrant whenNotPaused returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address _owner)
        public override nonReentrant returns (uint256)
    {
        _ensureLocalLiquidity(assets);
        return super.withdraw(assets, receiver, _owner);
    }

    /// @dev previewRedeem is evaluated before the recall so the liquidity check is exact.
    function redeem(uint256 shares, address receiver, address _owner)
        public override nonReentrant returns (uint256)
    {
        _ensureLocalLiquidity(previewRedeem(shares));
        return super.redeem(shares, receiver, _owner);
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    /// @dev Ensures at least `assets` USDC are held locally, recalling from Morpho if needed.
    ///      Pulls deficit+1 wei when headroom exists to absorb 1-wei ERC4626 rounding.
    function _ensureLocalLiquidity(uint256 assets) internal {
        uint256 local = IERC20(asset()).balanceOf(address(this));
        if (local >= assets) return;

        uint256 deficit = assets - local;
        IERC4626 vault_ = morphoVault;
        if (address(vault_) == address(0)) revert InsufficientLiquidity(assets, local);

        uint256 available = vault_.maxWithdraw(address(this));
        if (deficit > available) revert InsufficientLiquidity(assets, local + available);

        uint256 toWithdraw = deficit < available ? deficit + 1 : deficit;
        vault_.withdraw(toWithdraw, address(this), address(this));
        emit AssetsRecalled(address(vault_), toWithdraw);
    }

    function _availableLiquidity() internal view returns (uint256) {
        IERC4626 vault_ = morphoVault;
        uint256 fromVault = address(vault_) != address(0)
            ? vault_.maxWithdraw(address(this))
            : 0;
        return IERC20(asset()).balanceOf(address(this)) + fromVault;
    }
}
