// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;


contract TestHelper {
    function computePositionKey(address owner, int24 tickLower, int24 tickUpper) external view returns (bytes32) {
        return keccak256(abi.encodePacked(owner, tickLower, tickUpper));
    }
}
