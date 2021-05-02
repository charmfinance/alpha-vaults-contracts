// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;
pragma abicoder v2;

import "./BaseVault.sol";

contract PassiveRebalanceVault is BaseVault {
    int24 public baseThreshold;
    int24 public skewThreshold;

    /**
     * @param _pool Uniswap V3 pool
     * @param _baseThreshold Width of base range order in ticks
     * @param _skewThreshold Width of skew range order in ticks
     * @param _refreshCooldown How much time needs to pass between refresh()
     * calls in seconds
     * @param _totalSupplyCap Users can't deposit if total supply would exceed
     * this limit. Value of 0 means no cap.
     */
    constructor(
        address _pool,
        int24 _baseThreshold,
        int24 _skewThreshold,
        uint32 _twapDuration,
        uint256 _refreshCooldown,
        uint256 _totalSupplyCap
    ) BaseVault(_pool, _twapDuration, _refreshCooldown, _totalSupplyCap) {
        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_skewThreshold % tickSpacing == 0, "skewThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        require(_skewThreshold > 0, "skewThreshold");

        baseThreshold = _baseThreshold;
        skewThreshold = _skewThreshold;

        // TODO: nasty - figure out other way to do this
        _updateBaseRange();
    }

    function _baseRange() internal override returns (Range memory) {
        Range memory mid = _midRange();
        return Range(mid.lower - baseThreshold, mid.upper + baseThreshold);
    }

    function _skewRange() internal override returns (Range memory) {
        Range memory mid = _midRange();
        if (token0.balanceOf(address(this)) > 0) {
            return Range(mid.upper, mid.upper + skewThreshold);
        } else {
            return Range(mid.lower - skewThreshold, mid.lower);
        }
    }

    /**
     * @notice Set base threshold b. From the next refresh, the strategy will
     * move the base order to the range [mid - b, mid + b + 1].
     */
    function setBaseThreshold(int24 _baseThreshold) external onlyGovernance {
        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        baseThreshold = _baseThreshold;
    }

    /**
     * @notice Set skew threshold r. From the next refresh, the strategy
     * will move the skew order to the range [mid - r, mid] or
     * [mid + 1, mid + r + 1] depending on which token it holds more of.
     */
    function setRebalanceThreshold(int24 _skewThreshold) external onlyGovernance {
        require(_skewThreshold % tickSpacing == 0, "skewThreshold");
        require(_skewThreshold > 0, "skewThreshold");
        skewThreshold = _skewThreshold;
    }
}
