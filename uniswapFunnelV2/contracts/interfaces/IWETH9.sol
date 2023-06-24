pragma solidity >=0.5.0;

interface IWETH9 {
    function deposit() external payable;

    function transfer(address to, uint value) external returns (bool);

    function withdraw(uint) external;

    function approve(address spender, uint amount) external returns (bool);
}
