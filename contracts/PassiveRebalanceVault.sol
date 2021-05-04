// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/base/Multicall.sol";
import "@uniswap/v3-periphery/contracts/base/SelfPermit.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import "../interfaces/IVault.sol";

/**
 * @title   Passive Rebalance Vault
 * @notice  A vault that provides liquidity on Uniswap V3 on behalf of users
 */
contract PassiveRebalanceVault is
    IVault,
    IUniswapV3MintCallback,
    Multicall,
    SelfPermit,
    ERC20,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IUniswapV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;
    uint24 public fee;
    int24 public tickSpacing;

    int24 public baseThreshold;
    int24 public skewThreshold;
    int24 public maxTwapDeviation;
    uint32 public twapDuration;
    uint256 public rebalanceCooldown;
    uint256 public maxTotalSupply;

    int24 public baseLower;
    int24 public baseUpper;
    int24 public skewLower;
    int24 public skewUpper;

    address public governance;
    address public pendingGovernance;
    address public keeper;
    uint256 public lastUpdate;

    /**
     * @param _pool Underlying Uniswap V3 pool
     * @param _baseThreshold Width of base range order in ticks
     * @param _skewThreshold Width of skew range order in ticks
     * @param _rebalanceCooldown How much time needs to pass between rebalance()
     * calls in seconds
     * @param _maxTotalSupply Users can't deposit if total supply would exceed
     * this limit. Value of 0 means no cap.
     */
    constructor(
        address _pool,
        int24 _baseThreshold,
        int24 _skewThreshold,
        int24 _maxTwapDeviation,
        uint32 _twapDuration,
        uint256 _rebalanceCooldown,
        uint256 _maxTotalSupply
    ) ERC20("PassiveRebalanceVault", "PR") {
        require(_pool != address(0));
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        baseThreshold = _baseThreshold;
        skewThreshold = _skewThreshold;
        maxTwapDeviation = _maxTwapDeviation;
        twapDuration = _twapDuration;
        rebalanceCooldown = _rebalanceCooldown;
        maxTotalSupply = _maxTotalSupply;
        governance = msg.sender;

        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_skewThreshold % tickSpacing == 0, "skewThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        require(_skewThreshold > 0, "skewThreshold");
        require(_maxTwapDeviation >= 0, "maxTwapDeviation");

        (baseLower, baseUpper) = _baseRange();
        (skewLower, skewUpper) = _skewOrder();
    }

    function deposit(
        uint256 maxAmount0,
        uint256 maxAmount1,
        address to
    )
        external
        override
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(to != address(0), "to");

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            return _initialMint(maxAmount0, maxAmount1, to);
        }

        // Decrease slightly so amounts don't exceed max
        maxAmount0 = maxAmount0 >= 2 ? maxAmount0 - 2 : maxAmount0;
        maxAmount1 = maxAmount1 >= 2 ? maxAmount1 - 2 : maxAmount1;

        (uint256 total0, uint256 total1) = getTotalAmounts();
        assert(total0 > 0 || total1 > 0);

        // Set shares to the maximum possible value that implies amounts not
        // greater than maxAmount0 and maxAmount1
        if (maxAmount0.mul(total1) < maxAmount1.mul(total0) || total1 == 0) {
            shares = maxAmount0.mul(_totalSupply).div(total0);
        } else {
            shares = maxAmount1.mul(_totalSupply).div(total1);
        }
        require(shares > 0, "shares");

        // Deposit liquidity into Uniswap
        uint128 baseLiquidity = _liquidityForShares(baseLower, baseUpper, shares);
        uint128 skewLiquidity = _liquidityForShares(skewLower, skewUpper, shares);
        (uint256 baseAmount0, uint256 baseAmount1) =
            _mintLiquidity(baseLower, baseUpper, baseLiquidity, msg.sender);
        (uint256 skewAmount0, uint256 skewAmount1) =
            _mintLiquidity(skewLower, skewUpper, skewLiquidity, msg.sender);

        // Mint shares
        _mint(to, shares);
        require(maxTotalSupply == 0 || totalSupply() <= maxTotalSupply, "maxTotalSupply");

        // Return amounts deposited
        amount0 = baseAmount0.add(skewAmount0);
        amount1 = baseAmount1.add(skewAmount1);
        emit Deposit(msg.sender, to, shares, amount0, amount1);
    }

    function withdraw(uint256 shares, address to)
        external
        override
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        // Withdraw liquidity from Uniswap
        uint128 baseLiquidity = _liquidityForShares(baseLower, baseUpper, shares);
        uint128 skewLiquidity = _liquidityForShares(skewLower, skewUpper, shares);
        (uint256 baseAmount0, uint256 baseAmount1) =
            _burnLiquidity(baseLower, baseUpper, baseLiquidity, to, false);
        (uint256 skewAmount0, uint256 skewAmount1) =
            _burnLiquidity(skewLower, skewUpper, skewLiquidity, to, false);

        // Burn shares
        _burn(msg.sender, shares);

        // Return amounts withdrawn
        amount0 = baseAmount0.add(skewAmount0);
        amount1 = baseAmount1.add(skewAmount1);
        emit Withdraw(msg.sender, to, shares, amount0, amount1);
    }

    function rebalance() external override {
        require(keeper == address(0) || msg.sender == keeper, "keeper");
        require(block.timestamp >= lastUpdate.add(rebalanceCooldown), "cooldown");
        lastUpdate = block.timestamp;

        (, int24 mid, , , , , ) = pool.slot0();

        // Check price not too low or too high
        int24 maxThreshold = baseThreshold > skewThreshold ? baseThreshold : skewThreshold;
        require(mid > TickMath.MIN_TICK + maxThreshold + tickSpacing, "price too low");
        require(mid < TickMath.MAX_TICK - maxThreshold - tickSpacing, "price too high");

        // Withdraw all liquidity from Uniswap
        uint128 basePosition = _position(baseLower, baseUpper);
        uint128 skewPosition = _position(skewLower, skewUpper);
        _burnLiquidity(baseLower, baseUpper, basePosition, address(this), true);
        _burnLiquidity(skewLower, skewUpper, skewPosition, address(this), true);

        // Emit event with useful info
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        emit Rebalance(mid, balance0, balance1, totalSupply());

        // Check TWAP deviation. This check prevents price manipulation before
        // the rebalance and also avoids rebalancing when price has just spiked.
        int24 twap = getTwap();
        int24 deviation = mid > twap ? mid - twap : twap - mid;
        require(deviation <= maxTwapDeviation, "maxTwapDeviation");

        // Update base range and place order
        (baseLower, baseUpper) = _baseRange();
        uint128 baseLiquidity = _maxDepositable(baseLower, baseUpper);
        _mintLiquidity(baseLower, baseUpper, baseLiquidity, address(this));

        // Update skew range and place order
        (skewLower, skewUpper) = _skewOrder();
        uint128 skewLiquidity = _maxDepositable(skewLower, skewUpper);
        _mintLiquidity(skewLower, skewUpper, skewLiquidity, address(this));

        // Check base and skew ranges aren't the same, otherwise calculations
        // would fail elsewhere
        assert(baseLower != skewLower || baseUpper != skewUpper);
    }

    function _initialMint(
        uint256 maxAmount0,
        uint256 maxAmount1,
        address to
    )
        internal
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        shares = _liquidityForAmounts(baseLower, baseUpper, maxAmount0, maxAmount1);
        require(shares > 0, "shares");
        require(shares < type(uint128).max, "shares overflow");

        // Deposit liquidity into Uniswap. The initial mint only places an
        // order in the base range and ignores the skew range.
        (amount0, amount1) = _mintLiquidity(baseLower, baseUpper, uint128(shares), msg.sender);

        // Mint shares
        _mint(to, shares);
        require(maxTotalSupply == 0 || totalSupply() <= maxTotalSupply, "maxTotalSupply");
        emit Deposit(msg.sender, to, shares, amount0, amount1);
    }

    function _mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address payer
    ) internal returns (uint256, uint256) {
        if (liquidity > 0) {
            return pool.mint(address(this), tickLower, tickUpper, liquidity, abi.encode(payer));
        }
    }

    function _burnLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        address to,
        bool collectAll
    ) internal returns (uint256, uint256) {
        if (liquidity > 0) {
            // Burn liquidity
            (uint256 amount0, uint256 amount1) = pool.burn(tickLower, tickUpper, liquidity);

            // Collect amount owed
            uint128 collect0 = collectAll ? type(uint128).max : uint128(amount0);
            uint128 collect1 = collectAll ? type(uint128).max : uint128(amount1);
            if (collect0 > 0 || collect1 > 0) {
                return pool.collect(to, tickLower, tickUpper, collect0, collect1);
            }
        }
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
                TransferHelper.safeTransferFrom(address(token0), payer, msg.sender, amount0);
            }
            if (amount1 > 0) {
                TransferHelper.safeTransferFrom(address(token1), payer, msg.sender, amount1);
            }
        }
    }

    /**
     * @notice Calculates total holdings of token0 and token1, i.e. how
     * much this vault would hold if it withdrew all its liquidity.
     */
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        (, uint256 baseAmount0, uint256 baseAmount1) = getBaseLiquidityAndAmounts();
        (, uint256 skewAmount0, uint256 skewAmount1) = getSkewLiquidityAndAmounts();
        total0 = token0.balanceOf(address(this)).add(baseAmount0).add(skewAmount0);
        total1 = token1.balanceOf(address(this)).add(baseAmount1).add(skewAmount1);
    }

    function getBaseLiquidityAndAmounts()
        public
        view
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        liquidity = _position(baseLower, baseUpper);
        (amount0, amount1) = _amountsForLiquidity(baseLower, baseUpper, liquidity);
    }

    function getSkewLiquidityAndAmounts()
        public
        view
        returns (
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        )
    {
        liquidity = _position(skewLower, skewUpper);
        (amount0, amount1) = _amountsForLiquidity(skewLower, skewUpper, liquidity);
    }

    function getTwap() internal view returns (int24) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory _) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / twapDuration);
    }

    function _baseRange()
        internal view
        returns (
            int24,
            int24
        )
    {
        (int24 floorMid, int24 ceilMid) = _floorCeilMid();
        return (floorMid - baseThreshold, ceilMid + baseThreshold);
    }

    function _skewOrder()
        internal view
        returns (
            int24,
            int24
        )
    {
        (int24 floorMid, int24 ceilMid) = _floorCeilMid();
        uint128 bidLiquidity = _maxDepositable(floorMid - skewThreshold, floorMid);
        uint128 askLiquidity = _maxDepositable(ceilMid, ceilMid + skewThreshold);
        if (bidLiquidity > askLiquidity) {
            return (floorMid - skewThreshold, floorMid);
        } else {
            return (ceilMid, ceilMid + skewThreshold);
        }
    }

    /// @dev Convert shares into amount of liquidity
    function _liquidityForShares(
        int24 tickLower,
        int24 tickUpper,
        uint256 shares
    ) internal view returns (uint128) {
        uint256 position = uint256(_position(tickLower, tickUpper));
        uint256 liquidity = position.mul(shares).div(totalSupply());
        require(liquidity < type(uint128).max, "liquidity overflow");
        return uint128(liquidity);
    }

    /// @dev Amount of liquidity deposited by vault into Uniswap V3 pool for a
    /// certain range
    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionKey = keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
        (liquidity, , , , ) = pool.positions(positionKey);
    }

    /// @dev Maximum liquidity that can deposited in range by vault given
    /// its balances of token0 and token1
    function _maxDepositable(int24 tickLower, int24 tickUpper) internal view returns (uint128) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        return _liquidityForAmounts(tickLower, tickUpper, balance0, balance1);
    }

    /// @dev Current Uniswap price in ticks, rounded down and rounded up
    function _floorCeilMid() internal view returns (int24 floor, int24 ceil) {
        (, int24 mid, , , , , ) = pool.slot0();
        floor = _floor(mid);
        ceil = mid % tickSpacing == 0 ? mid : floor + tickSpacing;
    }

    /// @dev Round down towards negative infinity so that tick is a multiple of
    /// tickSpacing
    function _floor(int24 tick) internal view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }
        return compressed * tickSpacing;
    }

    function _amountsForLiquidity(
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

    function _liquidityForAmounts(
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

    /**
     * @notice Set base threshold b. From the next rebalance, the strategy will
     * move the base order to the range [mid - b, mid + b + 1].
     */
    function setBaseThreshold(int24 _baseThreshold) external onlyGovernance {
        require(_baseThreshold % tickSpacing == 0, "baseThreshold");
        require(_baseThreshold > 0, "baseThreshold");
        baseThreshold = _baseThreshold;
    }

    /**
     * @notice Set skew threshold r. From the next rebalance, the strategy
     * will move the skew order to the range [mid - r, mid] or
     * [mid + 1, mid + r + 1] depending on which token it holds more of.
     */
    function setSkewThreshold(int24 _skewThreshold) external onlyGovernance {
        require(_skewThreshold % tickSpacing == 0, "skewThreshold");
        require(_skewThreshold > 0, "skewThreshold");
        skewThreshold = _skewThreshold;
    }

    function setMaxTwapDeviation(int24 _maxTwapDeviation) external onlyGovernance {
        require(_maxTwapDeviation >= 0, "maxTwapDeviation");
        maxTwapDeviation = _maxTwapDeviation;
    }

    function setTwapDuration(uint32 _twapDuration) external onlyGovernance {
        twapDuration = _twapDuration;
    }

    /**
     * @notice Set rebalance cooldown - the number of seconds that need to pass
     * since the last rebalance before rebalance() can be called again.
     */
    function setRebalanceCooldown(uint256 _rebalanceCooldown) external onlyGovernance {
        rebalanceCooldown = _rebalanceCooldown;
    }

    /**
     * @notice Set maximum allowed total supply for a guarded launch. Users
     * can't deposit via mint() if their deposit would cause the total supply
     * to exceed this cap. A value of 0 means no limit.
     */
    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyGovernance {
        maxTotalSupply = _maxTotalSupply;
    }

    /**
     * @notice Governance address is not updated until the new governance
     * address has called acceptGovernance() to accept this responsibility.
     */
    function setGovernance(address _governance) external onlyGovernance {
        pendingGovernance = _governance;
    }

    /**
     * @notice Set keeper. If set, rebalance() can only be called by the keeper.
     * If equal to address zero, rebalance() can be called by any account.
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
