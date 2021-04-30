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
// TODO: cap
// TODO: multicall
// TODO: events
// TODO: protocol fee, charged in update()
// TODO: test getBalances
// TODO: floorTick -> current range (return Range)
// TODO: fuzzing
// TODO: only updater

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
    uint32 public twapDuration;
    uint256 public updateCooldown;
    uint256 public totalSupplyCap;

    struct Range {
        int24 tickLower;
        int24 tickUpper;
    }

    Range public baseRange;
    Range public rebalanceRange;

    address public governance;
    address public pendingGovernance;
    uint256 public lastUpdate;

    constructor(
        address _pool,
        int24 _baseThreshold,
        int24 _rebalanceThreshold,
        uint32 _twapDuration,
        uint256 _updateCooldown,
        uint256 _totalSupplyCap
    ) ERC20("name", "symbol") {
        require(_pool != address(0));
        pool = IUniswapV3Pool(_pool);

        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_rebalanceThreshold % tickSpacing == 0, "rebalanceThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        require(_rebalanceThreshold > 0, "rebalanceThreshold");

        baseThreshold = _baseThreshold;
        rebalanceThreshold = _rebalanceThreshold;
        twapDuration = _twapDuration;
        updateCooldown = _updateCooldown;
        totalSupplyCap = _totalSupplyCap;

        governance = msg.sender;

        int24 tick = _floorTick();
        int24 tickPlusSpacing = tick + tickSpacing;
        baseRange = Range(tick - baseThreshold, tickPlusSpacing + baseThreshold);
    }

    // function mint2(
    //     uint256 maxAmount0,
    //     uint256 maxAmount1,
    //     address to
    // ) external returns (uint256 shares) {
    //     require(to != address(0), "to");
    //     uint256 product0 = maxAmount0.mul(balance1);
    //     uint256 product1 = maxAmount1.mul(balance0);
    //     uint256 amount0 = product0 < product1 ? maxAmount0 : product1.div(balance1);
    //     uint256 amount1 = product1 < product0 ? maxAmount1 : product0.div(balance0);
    //     TransferHelper.safeTransferFrom(address(token0), msg.sender, address(this), amount0);
    //     TransferHelper.safeTransferFrom(address(token1), msg.sender, address(this), amount1);

    //     shares = product0 < product1 ? totalSupply().mul(amount0).div(balance0) : totalSupply().mul(amount1).div(balance1);
    //     _mint(shares);
    // }

    function mint(
        uint256 maxAmount0,
        uint256 maxAmount1,
        address to
    ) external returns (uint256 shares) {
        require(to != address(0), "to");

        uint256 totalSupply = totalSupply();
        if (totalSupply == 0) {
            return _initialMint(maxAmount0, maxAmount1, to);
        }

        // Decrease slightly so amounts don't exceed max
        maxAmount0 = maxAmount0.sub(2);
        maxAmount1 = maxAmount1.sub(2);

        (uint256 balance0, uint256 balance1) = getBalances();
        assert(balance0 > 0 || balance1 > 0);

        uint256 shares0 =
            balance0 > 0 ? maxAmount0.mul(totalSupply).div(balance0) : type(uint256).max;
        uint256 shares1 =
            balance1 > 0 ? maxAmount1.mul(totalSupply).div(balance1) : type(uint256).max;
        shares = shares0 < shares1 ? shares0 : shares1;
        require(shares > 0, "shares");

        uint128 baseAmount = _getProportionalLiquidity(baseRange, shares);
        uint128 rebalanceAmount = _getProportionalLiquidity(rebalanceRange, shares);
        _mintLiquidity(baseRange, baseAmount, msg.sender);
        _mintLiquidity(rebalanceRange, rebalanceAmount, msg.sender);

        _mint(to, shares);
        _checkTotalSupplyCap();
    }

    function _initialMint(
        uint256 maxAmount0,
        uint256 maxAmount1,
        address to
    ) internal returns (uint256 shares) {
        shares = _getLiquidityForAmounts(baseRange, maxAmount0, maxAmount1);
        require(shares < type(uint128).max, "shares");

        _mintLiquidity(baseRange, uint128(shares), msg.sender);
        _mint(to, shares);
        _checkTotalSupplyCap();
    }

    function _checkTotalSupplyCap() internal {
        if (totalSupplyCap > 0) {
            require(totalSupply() <= totalSupplyCap, "totalSupplyCap");
        }
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
        int24 tickPlusSpacing = tick + tickSpacing;
        // TODO: check twap matches

        // Remove all liquidity
        uint256 totalSupply = totalSupply();
        _burnLiquidity(baseRange, totalSupply, address(this), true);
        _burnLiquidity(rebalanceRange, totalSupply, address(this), true);

        // Update base range and add liquidity
        baseRange = Range(tick - baseThreshold, tickPlusSpacing + baseThreshold);
        uint128 baseAmount = _getMaxLiquidity(baseRange);
        _mintLiquidity(baseRange, baseAmount, address(this));

        // Update rebalance range
        if (token0.balanceOf(address(this)) > 0) {
            rebalanceRange = Range(tickPlusSpacing, tickPlusSpacing + rebalanceThreshold);
        } else {
            rebalanceRange = Range(tick - rebalanceThreshold, tick);
        }

        // Check base and rebalance ranges aren't the same, otherwise
        // calculations would fail elsewhere
        assert(
            baseRange.tickLower != rebalanceRange.tickLower ||
                baseRange.tickUpper != rebalanceRange.tickUpper
        );
        uint128 rebalanceAmount = _getMaxLiquidity(rebalanceRange);
        _mintLiquidity(rebalanceRange, rebalanceAmount, address(this));
    }

    function _mintLiquidity(
        Range memory range,
        uint128 amount,
        address payer
    ) internal {
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
        if (shares == 0) {
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
        // TODO check overflow
        uint128 amount = _getDepositedLiquidity(range);
        return uint128(uint256(amount).mul(shares).div(totalSupply()));
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

    function getBalances() public view returns (uint256 balance0, uint256 balance1) {
        balance0 = token0.balanceOf(address(this));
        balance1 = token1.balanceOf(address(this));

        (uint256 p0, uint256 p1) = getPassiveAmounts();
        (uint256 b0, uint256 b1) = getRebalanceAmounts();
        balance0 = balance0.add(p0).add(b0);
        balance1 = balance1.add(p1).add(b1);
    }

    function getPassiveAmounts() public view returns (uint256, uint256) {
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
        uint128 amount = _getDepositedLiquidity(rebalanceRange);
        return
            LiquidityAmounts.getAmountsForLiquidity(
                _sqrtRatioX96(),
                TickMath.getSqrtRatioAtTick(rebalanceRange.tickLower),
                TickMath.getSqrtRatioAtTick(rebalanceRange.tickUpper),
                amount
            );
    }

    function _getMaxLiquidity(Range memory range) internal view returns (uint128) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        return _getLiquidityForAmounts(range, balance0, balance1);
    }

    function _getLiquidityForAmounts(
        Range memory range,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        return
            LiquidityAmounts.getLiquidityForAmounts(
                _sqrtRatioX96(),
                TickMath.getSqrtRatioAtTick(range.tickLower),
                TickMath.getSqrtRatioAtTick(range.tickUpper),
                amount0,
                amount1
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

    function setTotalSupplyCap(uint256 _totalSupplyCap) external onlyGovernance {
        totalSupplyCap = _totalSupplyCap;
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
