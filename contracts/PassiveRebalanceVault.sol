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

    struct Range {
        int24 lower;
        int24 upper;
    }

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

    Range public baseRange;
    Range public skewRange;

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

        baseRange = _baseRange();
        skewRange = _skewRange();
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
        uint128 baseLiquidity = _liquidityForShares(baseRange, shares);
        uint128 skewLiquidity = _liquidityForShares(skewRange, shares);
        (uint256 base0, uint256 base1) =
            _mintLiquidity(baseRange, baseLiquidity, msg.sender);
        (uint256 skew0, uint256 skew1) =
            _mintLiquidity(skewRange, skewLiquidity, msg.sender);

        // Mint shares
        _mint(to, shares);
        require(maxTotalSupply == 0 || totalSupply() <= maxTotalSupply, "maxTotalSupply");

        // Return amounts deposited
        amount0 = base0.add(skew0);
        amount1 = base1.add(skew1);
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
        uint128 baseLiquidity = _liquidityForShares(baseRange, shares);
        uint128 skewLiquidity = _liquidityForShares(skewRange, shares);
        (uint256 base0, uint256 base1) =
            _burnLiquidity(baseRange, baseLiquidity, to, false);
        (uint256 skew0, uint256 skew1) =
            _burnLiquidity(skewRange, skewLiquidity, to, false);

        // Burn shares
        _burn(msg.sender, shares);

        // Return amounts withdrawn
        amount0 = base0.add(skew0);
        amount1 = base1.add(skew1);
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
        _burnLiquidity(baseRange, _deposited(baseRange), address(this), true);
        _burnLiquidity(skewRange, _deposited(skewRange), address(this), true);

        // Emit event with useful info
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        emit Rebalance(mid, balance0, balance1, totalSupply());

        // Check TWAP deviation. This check prevents price manipulation before
        // the rebalance and also avoids rebalancing when price has just spiked.
        int24 twap = _twap();
        int24 deviation = mid > twap ? mid - twap : twap - mid;
        require(deviation <= maxTwapDeviation, "maxTwapDeviation");

        // Update base range and place order
        baseRange = _baseRange();
        _mintLiquidity(baseRange, _maxLiquidity(baseRange), address(this));

        // Update skew range and place order
        skewRange = _skewRange();
        _mintLiquidity(skewRange, _maxLiquidity(skewRange), address(this));

        // Check base and skew ranges aren't the same, otherwise
        // calculations would fail elsewhere
        assert(baseRange.lower != skewRange.lower || baseRange.upper != skewRange.upper);
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
        shares = _liquidityForAmounts(baseRange, maxAmount0, maxAmount1);
        require(shares > 0, "shares");
        require(shares < type(uint128).max, "shares overflow");

        // Deposit liquidity into Uniswap. The initial mint only places an
        // order in the base range and ignores the skew range.
        (amount0, amount1) = _mintLiquidity(baseRange, uint128(shares), msg.sender);

        // Mint shares
        _mint(to, shares);
        require(maxTotalSupply == 0 || totalSupply() <= maxTotalSupply, "maxTotalSupply");
        emit Deposit(msg.sender, to, shares, amount0, amount1);
    }

    function _mintLiquidity(
        Range memory range,
        uint128 liquidity,
        address payer
    ) internal returns (uint256, uint256) {
        if (liquidity > 0) {
            return
                pool.mint(
                    address(this),
                    range.lower,
                    range.upper,
                    liquidity,
                    abi.encode(payer)
                );
        }
    }

    function _burnLiquidity(
        Range memory range,
        uint128 liquidity,
        address to,
        bool collectAll
    ) internal returns (uint256, uint256) {
        if (liquidity > 0) {
            // Burn liquidity
            (uint256 amount0, uint256 amount1) =
                pool.burn(range.lower, range.upper, liquidity);

            // Collect amount owed
            uint128 collect0 = collectAll ? type(uint128).max : uint128(amount0);
            uint128 collect1 = collectAll ? type(uint128).max : uint128(amount1);
            if (collect0 > 0 || collect1 > 0) {
                return pool.collect(to, range.lower, range.upper, collect0, collect1);
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

    /**
     * @notice Calculates total holdings of token0 and token1, i.e. how
     * much this vault would hold if it withdrew all its liquidity.
     */
    function getTotalAmounts() public view override returns (uint256, uint256) {
        (uint256 base0, uint256 base1) = getBaseAmounts();
        (uint256 skew0, uint256 skew1) = getSkewAmounts();
        return (
            token0.balanceOf(address(this)).add(base0).add(skew0),
            token1.balanceOf(address(this)).add(base1).add(skew1)
        );
    }

    function getBaseAmounts() public view returns (uint256, uint256) {
        return _amountsForLiquidity(baseRange, _deposited(baseRange));
    }

    function getSkewAmounts() public view returns (uint256, uint256) {
        return _amountsForLiquidity(skewRange, _deposited(skewRange));
    }

    /// @dev Convert shares into amount of liquidity
    function _liquidityForShares(Range memory range, uint256 shares)
        internal
        view
        returns (uint128)
    {
        uint256 liquidity = uint256(_deposited(range)).mul(shares).div(totalSupply());
        require(liquidity < type(uint128).max, "liquidity overflow");
        return uint128(liquidity);
    }

    /// @dev Amount of liquidity deposited by vault into Uniswap V3 pool for a
    /// certain range
    function _deposited(Range memory range) internal view returns (uint128 liquidity) {
        bytes32 positionKey =
            keccak256(abi.encodePacked(address(this), range.lower, range.upper));
        (liquidity, , , , ) = pool.positions(positionKey);
    }

    /// @dev Maximum liquidity that can deposited in range by vault given
    /// its balances of token0 and token1
    function _maxLiquidity(Range memory range) internal view returns (uint128) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        return _liquidityForAmounts(range, balance0, balance1);
    }

    function _baseRange() internal returns (Range memory) {
        (int24 floorMid, int24 ceilMid) = _midFloorCeil(mid);
        return Range(floorMid - baseThreshold, ceilMid + baseThreshold);
    }

    /// @dev Return range just above mid if there's excess token0 left over
    /// or range just below mid if there's excess token1 left over
    function _skewRange() internal returns (Range memory) {
        (int24 floorMid, int24 ceilMid) = _midFloorCeil(mid);
        Range memory bid = Range(floorMid - skewThreshold, floorMid);
        Range memory offer = Range(ceilMid, ceilMid + skewThreshold);

        // Return the range on which more liquidity can be placed
        return _maxLiquidity(bid) > _maxLiquidity(offer) ? bid : offer;
    }

    /// @dev Current Uniswap price in ticks, rounded down and rounded up
    function _midFloorCeil() internal view returns (Range memory) {
        (, int24 mid, , , , , ) = pool.slot0();
        int24 floorMid = _floor(mid);
        int24 ceilMid = mid % tickSpacing == 0 ? mid : floorMid + tickSpacing;
        return Range(floorMid, ceilMid);
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

    function _amountsForLiquidity(Range memory range, uint128 liquidity)
        internal
        view
        returns (uint256, uint256)
    {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(range.lower),
                TickMath.getSqrtRatioAtTick(range.upper),
                liquidity
            );
    }

    function _liquidityForAmounts(
        Range memory range,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        (uint160 sqrtRatioX96, , , , , , ) = pool.slot0();
        return
            LiquidityAmounts.getLiquidityForAmounts(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(range.lower),
                TickMath.getSqrtRatioAtTick(range.upper),
                amount0,
                amount1
            );
    }

    function _twap() internal view returns (int24) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory _) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / twapDuration);
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
