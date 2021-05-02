// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;
pragma abicoder v2;

import "./BaseVault.sol";

contract PassiveRebalanceVault is BaseVault {
    int24 public baseThreshold;
    int24 public skewThreshold;

    /**
     * @param _baseThreshold Width of base range order in ticks
     * @param _skewThreshold Width of skew range order in ticks
     */
    function initialize(
        address pool,
        uint32 twapDuration,
        uint256 refreshCooldown,
        uint256 totalSupplyCap,
        string memory name,
        string memory symbol,
        int24 _baseThreshold,
        int24 _skewThreshold
    ) public initializer {
        baseThreshold = _baseThreshold;
        skewThreshold = _skewThreshold;

        BaseVault.initialize(pool, twapDuration, refreshCooldown, totalSupplyCap, name, symbol);

        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_skewThreshold % tickSpacing == 0, "skewThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        require(_skewThreshold > 0, "skewThreshold");
    }

    function _baseRange() internal override returns (Range memory) {
        Range memory mid = _midRange();
        return Range(mid.lower - baseThreshold, mid.upper + baseThreshold);
    }

    function _skewRange() internal override returns (Range memory) {
        Range memory mid = _midRange();

        // Set range above mid if there's excess `token0` left over
        if (token0.balanceOf(address(this)) > 100) {
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
