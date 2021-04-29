// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";


// TODO add warnings

contract Router is IUniswapV3MintCallback, IUniswapV3SwapCallback {
    function mint(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external {
        pool.mint(
            msg.sender,
            tickLower,
            tickUpper,
            amount,
            abi.encode(msg.sender)
        );
    }

    function swap(IUniswapV3Pool pool, bool zeroForOne, int256 amountSpecified) external {
        pool.swap(
            msg.sender,
            zeroForOne,
            amountSpecified,
            zeroForOne
                ? TickMath.MIN_SQRT_RATIO + 1
                : TickMath.MAX_SQRT_RATIO - 1,
            abi.encode(msg.sender)
        );
    }

    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external override {
        _callback(amount0Owed, amount1Owed, data);
    }

    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external override {
        uint256 amount0 = amount0Delta > 0 ? uint256(amount0Delta) : 0;
        uint256 amount1 = amount1Delta > 0 ? uint256(amount1Delta) : 0;
        _callback(amount0, amount1, data);
    }

    function _callback(
        uint256 amount0, uint256 amount1, bytes calldata data) internal {
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        address sender = abi.decode(data, (address));

        TransferHelper.safeTransferFrom(
            pool.token0(),
            sender,
            msg.sender,
            amount0
        );
        TransferHelper.safeTransferFrom(
            pool.token1(),
            sender,
            msg.sender,
            amount1
        );
    }
}
