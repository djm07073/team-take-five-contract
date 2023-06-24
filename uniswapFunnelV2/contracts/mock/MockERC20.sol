// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;
import "./ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(
        uint amount,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_, decimals_) {
        _mint(msg.sender, amount);
    }

    function mint(uint amount, address to) external {
        _mint(to, amount);
    }
}
