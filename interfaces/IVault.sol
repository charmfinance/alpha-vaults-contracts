// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

interface IVault {
    function deposit(
        uint256,
        uint256,
        uint256,
        address
    ) external returns (uint256, uint256);

    function withdraw(uint256, uint256, uint256, address) external returns (uint256, uint256);

    function rebalance() external;

    function getTotalAmounts() external view returns (uint256, uint256);

    event Deposit(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    event Withdraw(
        address indexed sender,
        address indexed to,
        uint256 shares,
        uint256 amount0,
        uint256 amount1
    );

    event Rebalance(
        int24 tick,
        uint256 totalAmount0,
        uint256 totalAmount1,
        uint256 totalSupply
    );
}
