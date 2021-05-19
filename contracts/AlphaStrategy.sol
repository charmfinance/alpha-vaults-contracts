// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/base/Multicall.sol";
import "@uniswap/v3-periphery/contracts/base/SelfPermit.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

import "./AlphaVault.sol";

/**
 * @title   Alpha Strategy
 * @notice  Tells Alpha Vault to place two range orders:
 *
 *          1. Base order is placed between X - B and X + B + TS.
 *          2. Limit order is placed between X - L and X, or between X + TS
 *             and X + L + TS, depending on which token it holds more of.
 *
 *          where:
 *
 *              X = current tick rounded down to multiple of tick spacing
 *              TS = tick spacing
 *              B = base threshold
 *              L = limit threshold
 *
 *          Note that after these two orders, the vault should have deposited
 *          all its tokens and should only have a few wei left.
 *
 *          Because the limit order tries to sell whichever token the vault
 *          holds more of, the vault's holdings will have a tendency to get
 *          closer to a 1:1 balance. This enables it to continue providing
 *          liquidity without running out of inventory of either token, and
 *          achieves this without the need to swap directly on Uniswap and pay
 *          fees.
 */
contract AlphaStrategy {
    AlphaVault public vault;
    IUniswapV3Pool public pool;
    int24 public tickSpacing;

    int24 public baseThreshold;
    int24 public limitThreshold;
    int24 public maxTwapDeviation;
    uint32 public twapDuration;
    address public keeper;
    int24 public lastTick;

    /**
     * @param _vault Underlying Alpha Vault
     * @param _baseThreshold Used to determine base order range
     * @param _limitThreshold Used to determine limit order range
     * @param _maxTwapDeviation Max deviation from TWAP during rebalance
     * @param _twapDuration TWAP duration in seconds for rebalance check
     * @param _keeper Account that can call rebalance()
     */
    constructor(
        address _vault,
        int24 _baseThreshold,
        int24 _limitThreshold,
        int24 _maxTwapDeviation,
        uint32 _twapDuration,
        address _keeper
    ) {
        vault = AlphaVault(_vault);
        pool = vault.pool();
        tickSpacing = pool.tickSpacing();

        baseThreshold = _baseThreshold;
        limitThreshold = _limitThreshold;
        maxTwapDeviation = _maxTwapDeviation;
        twapDuration = _twapDuration;
        keeper = _keeper;

        _checkThreshold(_baseThreshold);
        _checkThreshold(_limitThreshold);
        require(_maxTwapDeviation >= 0, "maxTwapDeviation");
        require(_twapDuration > 0, "twapDuration");

        (, lastTick, , , , , ) = pool.slot0();
    }

    /**
     * Calculates new ranges for orders and calls vault.rebalance() so that
     * vault can update its positions.
     */
    function rebalance() external {
        // Rebalance can only be called by keeper. If 0x0, anyone can call.
        if (keeper != address(0)) {
            require(msg.sender == keeper, "keeper");
        }

        (, int24 tick, , , , , ) = pool.slot0();

        // Check price is not too close to min/max allowed by Uniswap. In
        // practice, the price would only be this extreme if all liquidity
        // was pulled from the underlying pool.
        int24 maxThreshold = baseThreshold > limitThreshold ? baseThreshold : limitThreshold;
        require(tick > TickMath.MIN_TICK + maxThreshold + tickSpacing, "price too low");
        require(tick < TickMath.MAX_TICK - maxThreshold - tickSpacing, "price too high");

        // Check TWAP deviation. This check prevents price manipulation before
        // the rebalance and also avoids rebalancing when price has just spiked.
        int24 twap = getTwap();
        int24 deviation = tick > twap ? tick - twap : twap - tick;
        require(deviation <= maxTwapDeviation, "maxTwapDeviation");

        int24 midFloor = _floor(tick);
        int24 midCeil = midFloor + tickSpacing;

        vault.rebalance(
            midFloor - baseThreshold,
            midCeil + baseThreshold,
            midFloor - limitThreshold,
            midFloor,
            midCeil,
            midCeil + limitThreshold
        );

        // Not used for calculations but store for convenience
        lastTick = tick;
    }

    function getTwap() public view returns (int24) {
        uint32 _twapDuration = twapDuration;
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = _twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / _twapDuration);
    }

    /// @dev Round tick down towards negative infinity towards nearest multiple
    /// of `tickSpacing`.
    function _floor(int24 tick) internal view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    /// @dev Check threshold is sensible.
    function _checkThreshold(int24 threshold) internal view {
        require(threshold > 0, "threshold not positive");
        require(threshold < TickMath.MAX_TICK, "threshold too high");
        require(threshold % tickSpacing == 0, "threshold not tick multiple");
    }

    function setKeeper(address _keeper) external onlyGovernance {
        keeper = _keeper;
    }

    function setBaseThreshold(int24 _baseThreshold) external onlyGovernance {
        _checkThreshold(_baseThreshold);
        baseThreshold = _baseThreshold;
    }

    function setLimitThreshold(int24 _limitThreshold) external onlyGovernance {
        _checkThreshold(_limitThreshold);
        limitThreshold = _limitThreshold;
    }

    function setMaxTwapDeviation(int24 _maxTwapDeviation) external onlyGovernance {
        require(_maxTwapDeviation >= 0, "maxTwapDeviation");
        maxTwapDeviation = _maxTwapDeviation;
    }

    function setTwapDuration(uint32 _twapDuration) external onlyGovernance {
        require(_twapDuration > 0, "twapDuration");
        twapDuration = _twapDuration;
    }

    /// @dev Uses same governance as underlying vault.
    modifier onlyGovernance {
        require(msg.sender == vault.governance(), "governance");
        _;
    }
}
