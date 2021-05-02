// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

interface IVault {
    function mint(
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

    function burn(uint256, address) external returns (uint256, uint256);

    function refresh() external;

    function getTotalAmounts() external view returns (uint256, uint256);
}
