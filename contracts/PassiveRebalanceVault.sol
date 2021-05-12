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
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

import "./UniswapV3Helper.sol";
import "../interfaces/IVault.sol";

/**
 * @title   Passive Rebalance Vault
 * @notice  Automatically manages liquidity on Uniswap V3 on behalf of users.
 *
 *          When a user calls deposit(), they have to add amounts of the two
 *          tokens proportional to the vault's current holdings. These are
 *          directly deposited into the Uniswap V3 pool. Similarly, when a user
 *          calls withdraw(), the proportion of liquidity is withdrawn from the
 *          pool and the resulting amounts are returned to the user.
 *
 *          The rebalance() method has to be called periodically. This method
 *          withdraws all liquidity from the pool, collects fees and then uses
 *          all the tokens it holds to place the two range orders below.
 *
 *              1. Base order is placed between X - B and X + B + TS.
 *              2. Limit order is placed between X - L and X, or between X + TS
 *                 and X + L + TS, depending on which token it holds more of.
 *
 *          where:
 *
 *              X = current tick rounded down to multiple of tick spacing
 *              TS = tick spacing
 *              B = base threshold
 *              L = limit threshold
 *
 *          Note that after the rebalance, the vault should theoretically
 *          have deposited all its tokens and shouldn't have any unused
 *          balance. The base order deposits equal values, so it uses up
 *          the entire balance of whichever token it holds less of. Then, the
 *          limit order is placed only one side of the current price so that
 *          the other token which it holds more of is used up.
 */
contract PassiveRebalanceVault is IVault, ERC20, ReentrancyGuard, UniswapV3Helper {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    uint256 public constant DUST_THRESHOLD = 1000;

    int24 public baseThreshold;
    int24 public limitThreshold;
    int24 public maxTwapDeviation;
    uint32 public twapDuration;
    uint256 public maxTotalSupply;

    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;

    address public governance;
    address public pendingGovernance;
    bool public finalized;
    address public keeper;

    /**
     * @param _pool Underlying Uniswap V3 pool
     * @param _baseThreshold Used to determine base range
     * @param _limitThreshold Used to determine limit range
     * @param _maxTwapDeviation Max deviation from TWAP during rebalance
     * @param _twapDuration TWAP duration in seconds for rebalance check
     * @param _maxTotalSupply Pause deposits if total supply exceeds this
     */
    constructor(
        address _pool,
        int24 _baseThreshold,
        int24 _limitThreshold,
        int24 _maxTwapDeviation,
        uint32 _twapDuration,
        uint256 _maxTotalSupply
    ) ERC20("Alpha Vault", "AV") UniswapV3Helper(_pool) {
        baseThreshold = _baseThreshold;
        limitThreshold = _limitThreshold;
        maxTwapDeviation = _maxTwapDeviation;
        twapDuration = _twapDuration;
        maxTotalSupply = _maxTotalSupply;
        governance = msg.sender;

        _checkThreshold(_baseThreshold);
        _checkThreshold(_limitThreshold);
        require(_maxTwapDeviation >= 0, "maxTwapDeviation");

        int24 mid = getTick();
        _checkMid(mid);
        (baseLower, baseUpper) = _baseRange(mid);
        (limitLower, limitUpper) = _bidRange(mid);
    }

    /**
     * @notice Deposit tokens in proportion to the vault's holdings.
     * @param amount0Desired Max amount of token 0 deposited
     * @param amount1Desired Max amount of token 1 deposited
     * @param amount0Min Revert if resulting `amount0` is less than this
     * @param amount1Min Revert if resulting `amount1` is less than this
     * @param to Recipient of shares
     * @return shares Number of shares minted
     * @return amount0 Amount of token0 deposited
     * @return amount1 Amount of token1 deposited
     */
    function deposit(
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    )
        external
        override
        nonReentrant
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        require(amount0Desired > 0 || amount1Desired > 0, "amounts both zero");
        require(to != address(0), "to");

        uint256 _totalSupply = totalSupply();
        if (_totalSupply == 0) {
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            shares = Math.max(amount0, amount1);
        } else {
            (uint256 total0, uint256 total1) = getTotalAmounts();
            total0 = Math.max(total0, 1);
            total1 = Math.max(total1, 1);

            uint256 cross = Math.min(amount0Desired.mul(total1), amount1Desired.mul(total0));
            amount0 = cross.div(total1).add(1); // round up
            amount1 = cross.div(total0).add(1); // round up
            amount0 = Math.min(amount0, amount0Desired);
            amount1 = Math.min(amount1, amount1Desired);

            shares = cross.mul(_totalSupply).div(total0).div(total1);
        }

        require(shares > 0, "shares zero");
        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");
        require(_totalSupply.add(shares) <= maxTotalSupply, "maxTotalSupply");

        // Mint shares to recipient
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, amount0, amount1);

        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
    }

    /**
     * @notice Withdraw tokens in proportion to the vault's holdings.
     * @param shares Shares burned by sender
     * @param amount0Min Revert if resulting amount0 is smaller than this
     * @param amount1Min Revert if resulting amount1 is smaller than this
     * @param to Recipient of tokens
     * @return amount0 Amount of token0 sent to recipient
     * @return amount1 Amount of token1 sent to recipient
     */
    function withdraw(
        uint256 shares,
        uint256 amount0Min,
        uint256 amount1Min,
        address to
    ) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        {
            // Calculate how much liquidity to withdraw
            uint128 baseLiquidity = _liquidityForShares(baseLower, baseUpper, shares);
            uint128 limitLiquidity = _liquidityForShares(limitLower, limitUpper, shares);

            // Withdraw liquidity from Uniswap pool
            (uint256 base0, uint256 base1) =
                burnLiquidity(baseLower, baseUpper, baseLiquidity);
            (uint256 limit0, uint256 limit1) =
                burnLiquidity(limitLower, limitUpper, limitLiquidity);

            // Collect amounts
            collect(baseLower, baseUpper, base0, base1, to);
            collect(limitLower, limitUpper, limit0, limit1, to);

            // Transfer out tokens proportional to unused balances
            uint256 unused0 = _withdrawUnused(token0, shares, to);
            uint256 unused1 = _withdrawUnused(token1, shares, to);

            // Sum up total amounts sent to recipient
            amount0 = base0.add(limit0).add(unused0);
            amount1 = base1.add(limit1).add(unused1);
        }

        // Burn shares
        _burn(msg.sender, shares);

        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");
        emit Withdraw(msg.sender, to, shares, amount0, amount1);
    }

    /**
     * @notice Update vault's positions depending on how the price has moved.
     * Reverts if current price deviates too much from the TWAP, or if it's too
     * extreme.
     */
    function rebalance() external override nonReentrant {
        require(keeper == address(0) || msg.sender == keeper, "keeper");

        int24 mid = getTick();
        _checkMid(mid);

        // Withdraw all liquidity and collect all fees from Uniswap pool
        uint128 basePosition = getPosition(baseLower, baseUpper);
        uint128 limitPosition = getPosition(limitLower, limitUpper);
        burnLiquidity(baseLower, baseUpper, basePosition);
        burnLiquidity(limitLower, limitUpper, limitPosition);
        collectAll(baseLower, baseUpper, address(this));
        collectAll(limitLower, limitUpper, address(this));

        // Emit event with useful info
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        emit Rebalance(mid, balance0, balance1, totalSupply());

        // Update base range and deposit liquidity in Uniswap pool. Base range
        // is symmetric so this order should use up all of one of the tokens.
        (baseLower, baseUpper) = _baseRange(mid);
        uint128 baseLiquidity = _maxDepositable(baseLower, baseUpper);
        mintLiquidity(baseLower, baseUpper, baseLiquidity, address(this));

        // Calculate limit ranges
        (int24 bidLower, int24 bidUpper) = _bidRange(mid);
        (int24 askLower, int24 askUpper) = _askRange(mid);
        uint128 bidLiquidity = _maxDepositable(bidLower, bidUpper);
        uint128 askLiquidity = _maxDepositable(askLower, askUpper);

        // After base order, should be left with just one token, so place a
        // limit order to sell that token
        if (bidLiquidity > askLiquidity) {
            (limitLower, limitUpper) = (bidLower, bidUpper);
            mintLiquidity(bidLower, bidUpper, bidLiquidity, address(this));
        } else {
            (limitLower, limitUpper) = (askLower, askUpper);
            mintLiquidity(askLower, askUpper, askLiquidity, address(this));
        }

        // Assert base and limit ranges aren't the same, otherwise positions
        // would get mixed up
        assert(baseLower != limitLower || baseUpper != limitUpper);
    }

    /// @dev If vault holds enough unused token balance, transfer proportional
    /// amount to sender. In general, the unused balance should be very low, so
    /// this transfer wouldn't be triggered.
    function _withdrawUnused(
        IERC20 token,
        uint256 shares,
        address to
    ) internal returns (uint256 amount) {
        uint256 balance = token.balanceOf(address(this));
        if (balance >= DUST_THRESHOLD) {
            amount = balance.mul(shares).div(totalSupply());
            token.safeTransfer(to, amount);
        }
    }

    /// @dev Convert shares into amount of liquidity. Shouldn't be called
    /// when total supply is 0.
    function _liquidityForShares(
        int24 tickLower,
        int24 tickUpper,
        uint256 shares
    ) internal view returns (uint128) {
        uint256 position = uint256(getPosition(tickLower, tickUpper));
        return uint128Safe(position.mul(shares).div(totalSupply()));
    }

    /// @dev Maximum liquidity that can deposited in range by vault given
    /// its balances of token0 and token1.
    function _maxDepositable(int24 tickLower, int24 tickUpper) internal view returns (uint128) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        return getLiquidityForAmounts(tickLower, tickUpper, balance0, balance1);
    }

    /// @dev Return lower and upper ticks for the base order. This order is
    /// roughly symmetric around the mid price.
    function _baseRange(int24 mid) internal view returns (int24, int24) {
        int24 midFloor = floorTick(mid);
        return (midFloor - baseThreshold, midFloor + tickSpacing + baseThreshold);
    }

    /// @dev Return lower and upper ticks for the bid limit order. This order
    /// sits just below the mid price and helps rebalance closer to 50/50.
    function _bidRange(int24 mid) internal view returns (int24, int24) {
        int24 midFloor = floorTick(mid);
        return (midFloor - limitThreshold, midFloor);
    }

    /// @dev Return lower and upper ticks for the ask limit order. This order
    /// sits just above the mid price and helps rebalance closer to 50/50.
    function _askRange(int24 mid) internal view returns (int24, int24) {
        int24 midCeil = floorTick(mid) + tickSpacing;
        return (midCeil, midCeil + limitThreshold);
    }

    /**
     * @notice Calculate total holdings of token0 and token1, or how much of
     * each token this vault would hold if it withdrew all its liquidity.
     */
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        (uint256 base0, uint256 base1) = getPositionAmounts(baseLower, baseUpper);
        (uint256 limit0, uint256 limit1) = getPositionAmounts(limitLower, limitUpper);
        total0 = token0.balanceOf(address(this)).add(base0).add(limit0);
        total1 = token1.balanceOf(address(this)).add(base1).add(limit1);
    }

    /// @dev Revert if current price is too close to min or max ticks allowed
    /// by Uniswap, or if it deviates too much from the TWAP. Should be called
    /// whenever base and limit ranges are updated. In practice, prices should
    /// only become this extreme if there's no liquidity in the Uniswap pool.
    function _checkMid(int24 mid) internal view {
        int24 maxThreshold = baseThreshold > limitThreshold ? baseThreshold : limitThreshold;
        require(mid > TickMath.MIN_TICK + maxThreshold + tickSpacing, "price too low");
        require(mid < TickMath.MAX_TICK - maxThreshold - tickSpacing, "price too high");

        // Check TWAP deviation. This check prevents price manipulation before
        // the rebalance and also avoids rebalancing when price has just spiked.
        int24 twap = getTwap(twapDuration);
        int24 deviation = mid > twap ? mid - twap : twap - mid;
        require(deviation <= maxTwapDeviation, "maxTwapDeviation");
    }

    function _checkThreshold(int24 threshold) internal view {
        require(threshold % tickSpacing == 0, "threshold not tick multiple");
        require(threshold < TickMath.MAX_TICK, "threshold too high");
        require(threshold > 0, "threshold not positive");
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
        twapDuration = _twapDuration;
    }

    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyGovernance {
        maxTotalSupply = _maxTotalSupply;
    }

    function setKeeper(address _keeper) external onlyGovernance {
        keeper = _keeper;
    }

    /**
     * @notice Renounce emergency powers.
     */
    function finalize() external onlyGovernance {
        finalized = true;
    }

    /**
     * @notice Transfer tokens to governance in case of emergency. Cannot be
     * called if already finalized.
     */
    function emergencyWithdraw(IERC20 token, uint256 amount) external onlyGovernance {
        require(!finalized, "finalized");
        token.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Burn liquidity and transfer tokens to governance in case of
     * emergency. Cannot be called if already finalized.
     */
    function emergencyBurn(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyGovernance {
        require(!finalized, "finalized");
        pool.burn(tickLower, tickUpper, liquidity);
        pool.collect(msg.sender, tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    /**
     * @notice Governance address is not updated until the new governance
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
        require(msg.sender == pendingGovernance, "pendingGovernance");
        governance = msg.sender;
    }

    modifier onlyGovernance {
        require(msg.sender == governance, "governance");
        _;
    }
}
