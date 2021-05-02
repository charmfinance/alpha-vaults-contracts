// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;
pragma abicoder v2;

import "./BaseVault.sol";


contract PassiveRebalanceVault is BaseVault {
    int24 public baseThreshold;
    int24 public rebalanceThreshold;

    /**
     * @param _pool Uniswap V3 pool
     * @param _baseThreshold Width of base range order in ticks
     * @param _rebalanceThreshold Width of rebalance range order in ticks
     * @param _refreshCooldown How much time needs to pass between refresh()
     * calls in seconds
     * @param _totalSupplyCap Users can't deposit if total supply would exceed
     * this limit. Value of 0 means no cap.
     */
    constructor(
        address _pool,
        int24 _baseThreshold,
        int24 _rebalanceThreshold,
        uint32 _twapDuration,
        uint256 _refreshCooldown,
        uint256 _totalSupplyCap
    ) BaseVault (_pool, _twapDuration, _refreshCooldown, _totalSupplyCap) {
        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_rebalanceThreshold % tickSpacing == 0, "rebalanceThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        require(_rebalanceThreshold > 0, "rebalanceThreshold");

        baseThreshold = _baseThreshold;
        rebalanceThreshold = _rebalanceThreshold;

        _updateBaseRange();
    }

    function _baseRange() internal override returns (Range memory) {
        Range memory mid = _midRange();
        return Range(mid.tickLower - baseThreshold, mid.tickUpper + baseThreshold);
    }

    function _rebalanceRange() internal override returns (Range memory) {
        Range memory mid = _midRange();
        if (token0.balanceOf(address(this)) > 0) {
            return Range(mid.tickUpper, mid.tickUpper + rebalanceThreshold);
        } else {
            return Range(mid.tickLower - rebalanceThreshold, mid.tickLower);
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
     * @notice Set rebalance threshold r. From the next refresh, the strategy
     * will move the rebalance order to the range [mid - r, mid] or
     * [mid + 1, mid + r + 1] depending on which token it holds more of.
     */
    function setRebalanceThreshold(int24 _rebalanceThreshold) external onlyGovernance {
        require(_rebalanceThreshold % tickSpacing == 0, "rebalanceThreshold");
        require(_rebalanceThreshold > 0, "rebalanceThreshold");
        rebalanceThreshold = _rebalanceThreshold;
    }
}
