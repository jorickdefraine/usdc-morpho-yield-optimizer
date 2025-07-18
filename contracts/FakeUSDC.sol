// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/token/ERC20/ERC20.sol";

contract FakeUSDC is ERC20 { 
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1000000 * (10** decimals()));
    }
    
    function decimals() public pure override returns (uint8) {
        return 6; // Real USDC uses 6 decimals
    }
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

