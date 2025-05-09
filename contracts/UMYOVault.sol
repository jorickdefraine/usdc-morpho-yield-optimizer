// SPDX-License-Identifier: MIT
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title USDC Morpho Yield Optimizer Vault
 * @notice ERC4626 vault that automatically deploys assets to Morpho's highest-yielding strategies
 * @dev Inherits from ERC4626 for standard tokenized vault functionality, Ownable for admin control,
 * and ReentrancyGuard for protection against reentrancy attacks.
 */
contract Vault is ERC4626, Ownable, ReentrancyGuard {
    IERC4626 public morphoVault;
    
    /// @notice Emitted when the Morpho vault target is updated
    event MorphoVaultUpdated(address indexed vault);
    
    /// @notice Emitted when assets are deployed to Morpho
    event AssetsDeployed(uint256 assets);
    
    /// @notice Emitted when assets are withdrawn from Morpho by admin
    event AssetsWithdrawn(uint256 assetsReceived, uint256 sharesBurned);
    
    /// @notice Emitted when a user deposits assets
    event VaultDeposit(
        address indexed caller,
        address indexed receiver,
        uint256 assets,
        uint256 shares
    );
    
    /// @notice Emitted when a user withdraws assets
    event VaultWithdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    
    /// @notice Emitted when a withdrawal fails due to insufficient liquidity
    event WithdrawalFailed(address indexed user, uint256 requested, uint256 available);

    /**
     * @notice Initializes the vault with the underlying asset
     * @param _asset The ERC20 token the vault accepts (e.g., USDC)
     */
    constructor(IERC20 _asset) 
        ERC4626(_asset) 
        ERC20("Vault USDC Morpho Yield Optimizer", "vUMYO")
        Ownable(msg.sender)
    {}

    /**
     * @notice Updates the target Morpho vault
     * @dev Only callable by owner
     * @param vault Address of the ERC4626-compatible Morpho vault
     */
    function setMorphoVault(IERC4626 vault) external onlyOwner {
        require(address(vault) != address(0), "Invalid vault address");
        morphoVault = vault;
        emit MorphoVaultUpdated(address(vault));
    }

    /**
     * @notice Returns the total assets managed by the vault
     * @return Sum of local assets and assets deployed to Morpho
     */
    function totalAssets() public view override returns (uint256) {
        uint256 localAssets = IERC20(asset()).balanceOf(address(this));
        uint256 deployedAssets = (address(morphoVault) != address(0)) 
            ? morphoVault.previewRedeem(morphoVault.balanceOf(address(this)))
            : 0;
        return localAssets + deployedAssets;
    }

    /**
     * @notice Deploys idle assets to Morpho vault for yield generation
     * @dev Only callable by owner. Uses infinite approval for gas efficiency.
     */
    function deployToMorpho() external onlyOwner {
        require(address(morphoVault) != address(0), "Vault not set");
        uint256 assets = IERC20(asset()).balanceOf(address(this));
        require(assets > 0, "No assets to deploy");

        // Gas optimization: Set infinite approval if not already set
        if (IERC20(asset()).allowance(address(this), address(morphoVault)) < assets) {
            IERC20(asset()).approve(address(morphoVault), type(uint256).max);
        }
        
        morphoVault.deposit(assets, address(this));
        emit AssetsDeployed(assets);
    }

    /**
     * @notice Deposit assets into the vault and mint shares
     * @param assets Amount of assets to deposit
     * @param receiver Address receiving the minted shares
     * @return shares Amount of shares minted
     */
    function deposit(uint256 assets, address receiver) 
        public 
        override 
        nonReentrant 
        returns (uint256 shares) 
    {
        shares = super.deposit(assets, receiver);
        emit VaultDeposit(msg.sender, receiver, assets, shares);
    }

    /**
     * @notice Withdraw assets from Morpho (admin only)
     * @param shares Amount of Morpho vault shares to redeem
     */
    function withdrawFromMorpho(uint256 shares) external onlyOwner {
        uint256 assets = morphoVault.previewRedeem(shares);
        morphoVault.redeem(shares, address(this), address(this));
        emit AssetsWithdrawn(assets, shares);
    }

    /**
     * @notice Withdraw assets from the vault
     * @dev Automatically recalls funds from Morpho if needed
     * @param assets Amount of assets to withdraw
     * @param receiver Address receiving the withdrawn assets
     * @param owner Address owning the shares being burned
     * @return shares Amount of shares burned
     */
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public override nonReentrant returns (uint256 shares) {
        uint256 localAssets = IERC20(asset()).balanceOf(address(this));
        
        if (localAssets < assets) {
            uint256 missingAssets = assets - localAssets;
            uint256 maxWithdrawable = morphoVault.maxWithdraw(address(this));
            
            if (missingAssets > maxWithdrawable) {
                emit WithdrawalFailed(owner, missingAssets, maxWithdrawable);
                revert("Insufficient liquidity");
            }
            
            morphoVault.withdraw(missingAssets, address(this), address(this));
        }
        
        shares = super.withdraw(assets, receiver, owner);
        emit VaultWithdraw(msg.sender, receiver, owner, assets, shares);
    }
}