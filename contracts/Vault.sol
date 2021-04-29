// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/Position.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

// TODO: chagne contract name to PassiveRebalancingVault
// TODO: extend interface
// TODO: choose name and symbol

/**
 * @title   Vault
 */
contract Vault is IUniswapV3MintCallback, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Position for mapping(bytes32 => Position.Info);

    IUniswapV3Pool public pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint24 public immutable fee;
    int24 public tickSpacing;

    int24 public baseThreshold;
    int24 public rebalanceThreshold;
    uint256 public updateCooldown;
    uint32 public twapDuration;

    address public governance;
    address public pendingGovernance;

    int24 public baseTickLower;
    int24 public baseTickUpper;
    int24 public rebalanceTickLower;
    int24 public rebalanceTickUpper;
    bool public shouldRebalance;

    struct Range {
        int24 tickLower;
        int24 tickUpper;
        bool isActive;
    }

    Range public baseRange;
    Range public rebalanceRange;

    uint256 public lastUpdate;

    constructor(
        address _pool,
        int24 _passiveWidth,
        int24 _rebalanceWidth,
        uint256 _updateCooldown,
        uint32 _twapDuration
    ) ERC20("name", "symbol") {
        require(_pool != address(0));
        pool = IUniswapV3Pool(_pool);

        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        baseThreshold = _passiveWidth;
        rebalanceThreshold = _rebalanceWidth;
        updateCooldown = _updateCooldown;
        twapDuration = _twapDuration;

        require(baseThreshold % tickSpacing == 0, "baseThreshold");
        require(rebalanceThreshold % tickSpacing == 0, "rebalanceThreshold");
        require(baseThreshold > 0, "baseThreshold");
        require(rebalanceThreshold > 0, "rebalanceThreshold");

        governance = msg.sender;

        int24 tick = _floorTick();
        baseRange.tickLower = tick - baseThreshold;
        baseRange.tickUpper = tick + tickSpacing + baseThreshold;
        baseRange.isActive = true;
    }

    // TODO: handle slippage
    function mint(uint256 shares, address to) external nonReentrant {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        _mintLiquidity(baseRange, shares, msg.sender);
        _mintLiquidity(rebalanceRange, shares, msg.sender);
        _mint(to, shares);
    }

    function burn(uint256 shares, address to) external nonReentrant {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        _burnLiquidity(baseRange, shares, to, false);
        _burnLiquidity(rebalanceRange, shares, to, false);
        _burn(msg.sender, shares);
    }

    function update() external {
        require(block.timestamp >= lastUpdate.add(updateCooldown), "cooldown");
        lastUpdate = block.timestamp;

        int24 tick = _floorTick();
        // TODO: check twap matches

        // Remove all liquidity
        _burnLiquidity(baseRange, totalSupply(), address(this), true);
        _burnLiquidity(rebalanceRange, totalSupply(), address(this), true);

        // Update passive range and add liquidity
        baseRange.tickLower = tick - baseThreshold;
        baseRange.tickUpper = tick + tickSpacing + baseThreshold;
        _mintMaxLiquidity(baseRange, address(this));

        // Update rebalance range
        if (token0.balanceOf(address(this)) > 0) {
            rebalanceRange = Range(
                tick + tickSpacing,
                tick + tickSpacing + rebalanceThreshold,
                true
            );
        } else if (token1.balanceOf(address(this)) > 0) {
            rebalanceRange = Range(tick - rebalanceThreshold, tick, true);
        } else {
            rebalanceRange = Range(0, 0, false);
        }

        // Check passive and rebalance ranges aren't the same, otherwise
        // calculations would fail elsewhere
        assert(
            baseRange.tickLower != rebalanceRange.tickLower ||
                baseRange.tickUpper != rebalanceRange.tickUpper
        );
        _mintMaxLiquidity(rebalanceRange, address(this));
    }

    function _mintLiquidity(
        Range memory range,
        uint256 shares,
        address payer
    ) internal {
        if (!range.isActive) {
            return;
        }

        uint128 amount = _getProportionalLiquidity(range, shares);
        if (amount == 0) {
            return;
        }

        pool.mint(
            address(this),
            range.tickLower,
            range.tickUpper,
            amount,
            abi.encode(payer)
        );
    }

    function _mintMaxLiquidity(Range memory range, address payer) internal {
        if (!range.isActive) {
            return;
        }

        uint128 amount =
            LiquidityAmounts.getLiquidityForAmounts(
                _sqrtRatioX96(),
                TickMath.getSqrtRatioAtTick(range.tickLower),
                TickMath.getSqrtRatioAtTick(range.tickUpper),
                token0.balanceOf(payer),
                token1.balanceOf(payer)
            );
        if (amount == 0) {
            return;
        }

        pool.mint(
            address(this),
            range.tickLower,
            range.tickUpper,
            amount,
            abi.encode(payer)
        );
    }

    function _burnLiquidity(
        Range memory range,
        uint256 shares,
        address to,
        bool collectAll
    ) internal {
        if (!range.isActive) {
            return;
        }

        uint128 amount = _getProportionalLiquidity(range, shares);
        if (amount == 0) {
            return;
        }

        (uint256 amount0, uint256 amount1) =
            pool.burn(range.tickLower, range.tickUpper, amount);
        uint128 collect0 = collectAll ? type(uint128).max : uint128(amount0);
        uint128 collect1 = collectAll ? type(uint128).max : uint128(amount1);
        if (collect0 == 0 && collect1 == 0) {
            return;
        }

        pool.collect(to, range.tickLower, range.tickUpper, collect0, collect1);
    }

    function _getProportionalLiquidity(Range memory range, uint256 shares)
        internal
        view
        returns (uint128)
    {
        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) {
            require(shares <= type(uint128).max);
            return uint128(shares);
        }

        // TODO check overflow
        uint128 amount = _getDepositedLiquidity(range);
        return uint128(uint256(amount).mul(shares).div(totalSupply));
    }

    function _getDepositedLiquidity(Range memory range)
        internal
        view
        returns (uint128 amount)
    {
        bytes32 positionKey =
            keccak256(abi.encodePacked(address(this), range.tickLower, range.tickUpper));
        (amount, , , , ) = pool.positions(positionKey);
    }

    function _getTwap() internal view returns (int24) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory _) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / twapDuration);
    }

    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        address payer = abi.decode(data, (address));

        if (payer == address(this)) {
            if (amount0 > 0) {
                TransferHelper.safeTransfer(address(token0), msg.sender, amount0);
            }
            if (amount1 > 0) {
                TransferHelper.safeTransfer(address(token1), msg.sender, amount1);
            }
        } else {
            if (amount0 > 0) {
                TransferHelper.safeTransferFrom(
                    address(token0),
                    payer,
                    msg.sender,
                    amount0
                );
            }
            if (amount1 > 0) {
                TransferHelper.safeTransferFrom(
                    address(token1),
                    payer,
                    msg.sender,
                    amount1
                );
            }
        }
    }

    function getBalances() external view returns (uint256 balance0, uint256 balance1) {
        balance0 = token0.balanceOf(address(this));
        balance1 = token1.balanceOf(address(this));

        (uint256 p0, uint256 p1) = getPassiveAmounts();
        (uint256 b0, uint256 b1) = getRebalanceAmounts();
        balance0 = balance0.add(p0).add(b0);
        balance1 = balance1.add(p1).add(b1);
    }

    function getPassiveAmounts() public view returns (uint256, uint256) {
        if (!baseRange.isActive) {
            return (0, 0);
        }
        uint128 amount = _getDepositedLiquidity(baseRange);
        return
            LiquidityAmounts.getAmountsForLiquidity(
                _sqrtRatioX96(),
                TickMath.getSqrtRatioAtTick(baseRange.tickLower),
                TickMath.getSqrtRatioAtTick(baseRange.tickUpper),
                amount
            );
    }

    function getRebalanceAmounts() public view returns (uint256, uint256) {
        if (!rebalanceRange.isActive) {
            return (0, 0);
        }
        uint128 amount = _getDepositedLiquidity(rebalanceRange);
        return
            LiquidityAmounts.getAmountsForLiquidity(
                _sqrtRatioX96(),
                TickMath.getSqrtRatioAtTick(rebalanceRange.tickLower),
                TickMath.getSqrtRatioAtTick(rebalanceRange.tickUpper),
                amount
            );
    }

    function _sqrtRatioX96() internal view returns (uint160 sqrtRatioX96) {
        (sqrtRatioX96, , , , , , ) = pool.slot0();
    }

    function _floorTick() internal view returns (int24) {
        (, int24 tick, , , , , ) = pool.slot0();

        // Round towards negative infinity
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }
        return compressed * tickSpacing;
    }

    function setBaseThreshold(int24 _baseThreshold) external onlyGovernance {
        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        baseThreshold = _baseThreshold;
    }

    function setRebalanceThreshold(int24 _rebalanceThreshold) external onlyGovernance {
        require(_rebalanceThreshold % tickSpacing == 0, "rebalanceThreshold");
        require(_rebalanceThreshold > 0, "rebalanceThreshold");
        rebalanceThreshold = _rebalanceThreshold;
    }

    function setUpdateCooldown(uint256 _updateCooldown) external onlyGovernance {
        updateCooldown = _updateCooldown;
    }

    function setTwapDuration(uint32 _twapDuration) external onlyGovernance {
        twapDuration = _twapDuration;
    }

    /**
     * @notice Governance address is not update until the new governance
     * address has called acceptGovernance() to accept this responsibility.
     */
    function setGovernance(address _governance) external onlyGovernance {
        pendingGovernance = _governance;
    }

    /**
     * @notice setGovernance() should be called by the existing governance
     * address prior to calling this function.
     */
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "!pendingGovernance");
        governance = msg.sender;
    }

    modifier onlyGovernance {
        require(msg.sender == governance, "!governance");
        _;
    }
}
