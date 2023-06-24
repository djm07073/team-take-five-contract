// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

interface IMintableERC20 {
    function mint(address to, uint256 amount) external;
}
