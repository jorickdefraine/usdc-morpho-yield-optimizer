// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract FakeMorpho is ERC4626 {
    uint256 public exchangeRate = 1e18;

    constructor(IERC20 _asset) 
        ERC4626(_asset) 
        ERC20("Morpho Vault Un", "mvuUMYO") {}

    function setExchangeRate(uint256 newRate) external {
        exchangeRate = newRate;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) * exchangeRate / 1e18;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
    // Return slightly more to account for rounding
    return (balanceOf(owner) * exchangeRate / 1e18) + 1;
}

}