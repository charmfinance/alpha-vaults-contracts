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

// TODO: choose name and symbol
// TODO: events
// TODO: test getBalances
// TODO: fuzzing
// TODO: add twap check

/**
 * @title   Passive Rebalance Vault
 * @notice  A vault that makes it easy for users to provide liquidity on
 *          Uniswap V3 in a smart way.
 */
contract PassiveRebalanceVault is IUniswapV3MintCallback, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;
    using Position for mapping(bytes32 => Position.Info);

    struct Range {
        int24 tickLower;
        int24 tickUpper;
    }

    IUniswapV3Pool public pool;
    IERC20 public immutable token0;
    IERC20 public immutable token1;
    uint24 public immutable fee;
    int24 public tickSpacing;

    int24 public baseThreshold;
    int24 public rebalanceThreshold;
    uint32 public twapDuration;
    uint256 public refreshCooldown;
    uint256 public totalSupplyCap;

    Range public baseRange;
    Range public rebalanceRange;

    address public governance;
    address public pendingGovernance;
    address public keeper;
    uint256 public lastUpdate;

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
    ) ERC20("Passive Rebalance Vault", "PRV") {
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
        refreshCooldown = _refreshCooldown;
        totalSupplyCap = _totalSupplyCap;

        governance = msg.sender;

        Range memory mid = _midRange();
        baseRange = Range(mid.tickLower - baseThreshold, mid.tickUpper + baseThreshold);
    }

    function mint(
        uint256 maxAmount0,
        uint256 maxAmount1,
        address to
    ) external returns (uint256 shares) {
        require(to != address(0), "to");

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return _initialMint(maxAmount0, maxAmount1, to);
        }

        // Decrease slightly so amounts don't exceed max
        maxAmount0 = maxAmount0.sub(2);
        maxAmount1 = maxAmount1.sub(2);

        (uint256 balance0, uint256 balance1) = getBalances();
        assert(balance0 > 0 || balance1 > 0);

        uint256 shares0 =
            balance0 > 0 ? maxAmount0.mul(_totalSupply).div(balance0) : type(uint256).max;
        uint256 shares1 =
            balance1 > 0 ? maxAmount1.mul(_totalSupply).div(balance1) : type(uint256).max;
        shares = shares0 < shares1 ? shares0 : shares1;
        require(shares > 0, "shares");

        uint128 baseAmount = _liquidityForShares(baseRange, shares);
        uint128 rebalanceAmount = _liquidityForShares(rebalanceRange, shares);
        _mintLiquidity(baseRange, baseAmount, msg.sender);
        _mintLiquidity(rebalanceRange, rebalanceAmount, msg.sender);

        _mint(to, shares);
        require(totalSupplyCap == 0 || totalSupply() <= totalSupplyCap, "totalSupplyCap");
    }

    function _initialMint(
        uint256 maxAmount0,
        uint256 maxAmount1,
        address to
    ) internal returns (uint256 shares) {
        shares = _liquidityForAmounts(baseRange, maxAmount0, maxAmount1);
        require(shares < type(uint128).max, "shares");

        _mintLiquidity(baseRange, uint128(shares), msg.sender);
        _mint(to, shares);
        require(totalSupplyCap == 0 || totalSupply() <= totalSupplyCap, "totalSupplyCap");
    }

    function burn(uint256 shares, address to) external nonReentrant {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        _burnLiquidity(baseRange, shares, to, false);
        _burnLiquidity(rebalanceRange, shares, to, false);
        _burn(msg.sender, shares);
    }

    function refresh() external {
        require(keeper == address(0) || msg.sender == keeper, "keeper");
        require(block.timestamp >= lastUpdate.add(refreshCooldown), "cooldown");
        lastUpdate = block.timestamp;

        Range memory mid = _midRange();
        // TODO: check twap matches

        // Remove all liquidity
        uint256 totalSupply = totalSupply();
        _burnLiquidity(baseRange, totalSupply, address(this), true);
        _burnLiquidity(rebalanceRange, totalSupply, address(this), true);

        // Update base range and add liquidity
        baseRange = Range(mid.tickLower - baseThreshold, mid.tickUpper + baseThreshold);
        uint128 baseAmount = _maxLiquidity(baseRange);
        _mintLiquidity(baseRange, baseAmount, address(this));

        // Update rebalance range
        if (token0.balanceOf(address(this)) > 0) {
            rebalanceRange = Range(mid.tickUpper, mid.tickUpper + rebalanceThreshold);
        } else {
            rebalanceRange = Range(mid.tickLower - rebalanceThreshold, mid.tickLower);
        }

        // Check base and rebalance ranges aren't the same, otherwise
        // calculations would fail elsewhere
        assert(
            baseRange.tickLower != rebalanceRange.tickLower ||
                baseRange.tickUpper != rebalanceRange.tickUpper
        );
        uint128 rebalanceAmount = _maxLiquidity(rebalanceRange);
        _mintLiquidity(rebalanceRange, rebalanceAmount, address(this));
    }

    function _mintLiquidity(
        Range memory range,
        uint128 liquidity,
        address payer
    ) internal {
        if (liquidity == 0) {
            return;
        }

        pool.mint(
            address(this),
            range.tickLower,
            range.tickUpper,
            liquidity,
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

        uint128 liquidity = _liquidityForShares(range, shares);
        if (liquidity == 0) {
            return;
        }

        (uint256 amount0, uint256 amount1) =
            pool.burn(range.tickLower, range.tickUpper, liquidity);
        uint128 collect0 = collectAll ? type(uint128).max : uint128(amount0);
        uint128 collect1 = collectAll ? type(uint128).max : uint128(amount1);
        if (collect0 == 0 && collect1 == 0) {
            return;
        }

        pool.collect(to, range.tickLower, range.tickUpper, collect0, collect1);
    }

    /// @dev Callback for Uniswap V3 pool
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

        (uint256 p0, uint256 p1) =
            _amountsForLiquidity(baseRange, _deposited(baseRange));
        (uint256 b0, uint256 b1) =
            _amountsForLiquidity(
                rebalanceRange,
                _deposited(rebalanceRange)
            );
        balance0 = balance0.add(p0).add(b0);
        balance1 = balance1.add(p1).add(b1);
    }

    function _liquidityForShares(Range memory range, uint256 shares)
        internal
        view
        returns (uint128)
    {
        uint128 liquidity = _deposited(range);
        // TODO check overflow
        return uint128(uint256(liquidity).mul(shares).div(totalSupply()));
    }

    function _deposited(Range memory range)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionKey =
            keccak256(abi.encodePacked(address(this), range.tickLower, range.tickUpper));
        (liquidity, , , , ) = pool.positions(positionKey);
    }

    /// @dev Maximum liquidity that can deposited in `range` by vault given
    /// its balances of `token0` and `token1`
    function _maxLiquidity(Range memory range) internal view returns (uint128) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        return _liquidityForAmounts(range, balance0, balance1);
    }

    function _amountsForLiquidity(Range memory range, uint128 liquidity)
        internal
        view
        returns (uint256, uint256)
    {
        return
            LiquidityAmounts.getAmountsForLiquidity(
                _sqrtRatioX96(),
                TickMath.getSqrtRatioAtTick(range.tickLower),
                TickMath.getSqrtRatioAtTick(range.tickUpper),
                liquidity
            );
    }

    function _liquidityForAmounts(
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

    function _getTwap() internal view returns (int24) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory _) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / twapDuration);
    }

    /// @dev Current Uniswap price in the form of sqrt(price) * 2^96
    function _sqrtRatioX96() internal view returns (uint160 sqrtRatioX96) {
        (sqrtRatioX96, , , , , , ) = pool.slot0();
    }

    /// @dev Current Uniswap price in ticks, rounded down and rounded up
    function _midRange() internal view returns (Range memory) {
        (, int24 tick, , , , , ) = pool.slot0();

        // Round towards negative infinity
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }

        int24 tickFloor = compressed * tickSpacing;
        return Range(tickFloor, tickFloor + tickSpacing);
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

    /**
     * @notice Set refresh cooldown - the number of seconds that need to pass
     * since the last refresh before refresh() can be called again.
     */
    function setRefreshCooldown(uint256 _refreshCooldown) external onlyGovernance {
        refreshCooldown = _refreshCooldown;
    }

    function setTwapDuration(uint32 _twapDuration) external onlyGovernance {
        twapDuration = _twapDuration;
    }

    /**
     * @notice Set maximum allowed total supply for a guarded launch. Users
     * can't deposit via mint() if their deposit would cause the total supply
     * to exceed this cap. A value of 0 means no limit.
     */
    function setTotalSupplyCap(uint256 _totalSupplyCap) external onlyGovernance {
        totalSupplyCap = _totalSupplyCap;
    }

    /**
     * @notice Governance address is not updated until the new governance
     * address has called acceptGovernance() to accept this responsibility.
     */
    function setGovernance(address _governance) external onlyGovernance {
        pendingGovernance = _governance;
    }

    /**
     * @notice Set keeper. If set, refresh() can only be called by the keeper.
     * If equal to address zero, refresh() can be called by any account.
     */
    function setKeeper(address _keeper) external onlyGovernance {
        keeper = _keeper;
    }

    /**
     * @notice setGovernance() should be called by the existing governance
     * address prior to calling this function.
     */
    function acceptGovernance() external {
        require(msg.sender == pendingGovernance, "pendingGovernance");
        governance = msg.sender;
    }

    modifier onlyGovernance {
        require(msg.sender == governance, "governance");
        _;
    }
}
