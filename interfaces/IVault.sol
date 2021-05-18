// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

interface IVault {
    function deposit(
        uint256,
        uint256,
        uint256,
        uint256,
        address
    )
        external
        returns (
            uint256,
            uint256,
            uint256
        );

    function withdraw(
        uint256,
        uint256,
        uint256,
        address
    ) external returns (uint256, uint256);

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

    event Snapshot(int24 tick, uint256 totalAmount0, uint256 totalAmount1, uint256 totalSupply);

    event CollectFees(
        uint256 fees0,
        uint256 fees1,
        uint256 protocolFees0,
        uint256 protocolFees1
    );
}
