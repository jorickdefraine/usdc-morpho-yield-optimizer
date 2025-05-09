// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract USDCMorphoYieldOptimizer is ERC20 { 
    constructor() ERC20("USDCMorphoYieldOptimizer", "UMYO") {
        _mint(msg.sender, 1000000 * (10** decimals()));
    }
}

