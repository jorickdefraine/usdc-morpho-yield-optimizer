// SPDX-License-Identifier: MIT

pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

contract Vault is ERC4626 {

    constructor(IERC20 _asset) 
        ERC4626(_asset) 
        ERC20("Morpho Vault Un", "mvuUMYO") {}

}