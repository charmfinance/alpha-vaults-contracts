// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";


abstract contract UniswapV3Helper is IUniswapV3MintCallback {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IUniswapV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;
    uint24 public fee;
    int24 public tickSpacing;

    constructor(
        address _pool
    ) {
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();
    }

    function mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address payer
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity > 0) {
            (amount0, amount1) = pool.mint(
                address(this),
                tickLower,
                tickUpper,
                liquidity,
                abi.encode(payer)
            );
        }
    }

    function burnLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity > 0) {
            (amount0, amount1) = pool.burn(tickLower, tickUpper, liquidity);
        }
    }

    function collect(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        address to
    ) internal returns (uint256 collect0, uint256 collect1) {
        if (amount0 > 0 || amount1 > 0) {
            (collect0, collect1) = pool.collect(to, tickLower, tickUpper, uint128Safe(amount0), uint128Safe(amount1));
        }
    }

    function collectAll(
        int24 tickLower,
        int24 tickUpper,
        address to
    ) internal returns (uint256, uint256) {
        return pool.collect(to, tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    /**
     * @notice Fetch TWAP from Uniswap V3 pool. If `twapDuration` is 0, returns
     * current price.
     */
    function getTwap(uint32 duration) public view returns (int24) {
        if (duration == 0) {
            return getTick();
        }

        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = duration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / duration);
    }

    /// @dev Amount of liquidity deposited by vault into Uniswap V3 pool for a
    /// certain range.
    function getPosition(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (liquidity, , , , ) = pool.positions(positionKey);
    }

    function getPositionAmounts(int24 tickLower, int24 tickUpper) internal view returns (uint256 amount0, uint256 amount1) {
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) = pool.positions(positionKey);
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();

        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
        amount0 = amount0.add(uint256(tokensOwed0));
        amount1 = amount1.add(uint256(tokensOwed1));
    }

    /// @dev Wrapper around `getAmountsForLiquidity()` for convenience.
    function getAmountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal view returns (uint256, uint256) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }

    /// @dev Wrapper around `getLiquidityForAmounts()` for convenience.
    function getLiquidityForAmounts(
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                amount0,
                amount1
            );
    }

    /// @dev Get current price in ticks from pool
    function getTick() internal view returns (int24 tick) {
        (, tick, , , , , ) = pool.slot0();
    }

    /// @dev Round tick down towards negative infinity so that it is a multiple
    /// of `tickSpacing`.
    function floorTick(int24 tick) internal view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function uint128Safe(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        address payer = abi.decode(data, (address));

        if (payer == address(this)) {
            if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
            if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
        } else {
            if (amount0 > 0) token0.safeTransferFrom(payer, msg.sender, amount0);
            if (amount1 > 0) token1.safeTransferFrom(payer, msg.sender, amount1);
        }
    }
}
