// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC4626} from "@openzeppelin/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {FakeUSDC} from "./FakeUSDC.sol";

/**
 * @title FakeMorpho
 * @notice Minimal ERC4626 mock for testing UMYOVault. Uses real OZ ERC4626 accounting.
 *
 * Yield simulation:
 *   - simulateYield(amount): mint USDC into this vault → each share worth more
 *   - simulateLoss(amount): remove USDC from this vault → each share worth less
 *
 * These helpers make totalAssets() reflect real token balances, so all ERC4626 math
 * (convertToAssets, maxWithdraw, redeem) is correct by construction.
 */
contract FakeMorpho is ERC4626 {
    constructor(IERC20 _asset)
        ERC4626(_asset)
        ERC20("Mock Morpho Vault", "mMorpho")
    {}

    /// @notice Simulate yield accrual: inject USDC so shares appreciate.
    function simulateYield(uint256 additionalAssets) external {
        FakeUSDC(address(asset())).mint(address(this), additionalAssets);
    }

    /// @notice Simulate a loss: remove USDC so shares depreciate.
    /// @dev Sends to address(1) since ERC20 transfer(address(0)) reverts.
    function simulateLoss(uint256 lossAssets) external {
        IERC20(asset()).transfer(address(1), lossAssets);
    }
}
