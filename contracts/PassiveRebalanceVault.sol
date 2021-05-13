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
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

import "../interfaces/IVault.sol";

/**
 * @title   Passive Rebalance Vault
 * @notice  A vault that provides liquidity on Uniswap V3.
 *
 *          Each deployed vault manages liquidity on a single Uniswap V3 pool.
 *          Users enter and leave a vault via the deposit() and withdraw()
 *          methods.
 *
 *          When a user calls deposit(), they deposit both tokens proportional
 *          to the vault's current holdings. These tokens sit in the vault and
 *          are not used for liquidity on Uniswap until the next rebalance.
 *
 *          When a user calls withdraw(), the proportional amount of liquidity
 *          from each position is withdrawn from the Uniswap pool and the
 *          resulting amounts, as well as the proportion of unused balances in
 *          the vault, are returned to the user.
 *
 *          The rebalance() method has to be called periodically. This method
 *          withdraws all liquidity from the pool, collects fees and then uses
 *          all the tokens it holds to place the two following range orders.
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
 *          Note that after the rebalance, the vault should have deposited all
 *          its tokens and shouldn't have any unused balance apart from small
 *          rounding amounts.
 *
 *          Because the limit order tries to sell whichever token the vault
 *          holds more of, the vault's holdings will have a tendency to get
 *          closer to a 50/50 balance. This enables it to continue providing
 *          liquidity without running out of inventory of either token, and
 *          achieves this without the need to swap directly on Uniswap and pay
 *          fees.
 */
contract PassiveRebalanceVault is IVault, IUniswapV3MintCallback, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IUniswapV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;
    uint24 public fee;
    int24 public tickSpacing;

    int24 public baseThreshold;
    int24 public limitThreshold;
    int24 public maxTwapDeviation;
    uint32 public twapDuration;
    uint256 public protocolFee;
    uint256 public maxTotalSupply;

    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;
    uint256 public fees0;
    uint256 public fees1;

    address public governance;
    address public pendingGovernance;
    bool public finalized;
    address public keeper;

    /**
     * @param _pool Underlying Uniswap V3 pool
     * @param _baseThreshold Used to determine range of base order
     * @param _limitThreshold Used to determine range of limit order
     * @param _maxTwapDeviation Max deviation from TWAP during rebalance
     * @param _twapDuration TWAP duration in seconds for rebalance check
     * @param _protocolFee Fee on deposits expressed as multiple of 1e-6
     * @param _maxTotalSupply Pause deposits if total supply exceeds this
     */
    constructor(
        address _pool,
        int24 _baseThreshold,
        int24 _limitThreshold,
        int24 _maxTwapDeviation,
        uint32 _twapDuration,
        uint256 _protocolFee,
        uint256 _maxTotalSupply
    ) ERC20("Alpha Vault", "AV") {
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        baseThreshold = _baseThreshold;
        limitThreshold = _limitThreshold;
        maxTwapDeviation = _maxTwapDeviation;
        twapDuration = _twapDuration;
        protocolFee = _protocolFee;
        maxTotalSupply = _maxTotalSupply;
        governance = msg.sender;
        keeper = msg.sender;

        _checkThreshold(_baseThreshold);
        _checkThreshold(_limitThreshold);
        require(_maxTwapDeviation >= 0, "maxTwapDeviation");
        require(_twapDuration > 0, "twapDuration");
        require(_protocolFee < 1e6, "protocolFee");

        (, int24 mid, , , , , ) = pool.slot0();
        _checkMid(mid);
    }

    /**
     * @notice Deposit tokens in proportion to the vault's holdings.
     * @param amount0Desired Max amount of token0 deposited
     * @param amount1Desired Max amount of token1 deposited
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
            // For the first deposit, just transfer in the amounts specified
            // by the user
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

        // Update fees
        uint256 _protocolFee = protocolFee;
        if (_protocolFee > 0) {
            shares = shares.sub(shares.mul(_protocolFee).div(1e6));
            fees0 = fees0.add(amount0.mul(_protocolFee).div(1e6));
            fees1 = fees1.add(amount1.mul(_protocolFee).div(1e6));
        }

        require(shares > 0, "shares");
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
     * @param amount0Min Revert if resulting `amount0` is smaller than this
     * @param amount1Min Revert if resulting `amount1` is smaller than this
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

        (uint256 base0, uint256 base1) = _burnLiquidityShare(baseLower, baseUpper, shares, to);
        (uint256 limit0, uint256 limit1) =
            _burnLiquidityShare(limitLower, limitUpper, shares, to);

        // Transfer out tokens proportional to unused balances
        uint256 _totalSupply = totalSupply();
        uint256 unused0 = _balance0().mul(shares).div(_totalSupply);
        uint256 unused1 = _balance1().mul(shares).div(_totalSupply);
        if (unused0 > 0) token0.safeTransfer(to, unused0);
        if (unused1 > 0) token1.safeTransfer(to, unused1);

        // Sum up total amounts sent to recipient
        amount0 = base0.add(limit0).add(unused0);
        amount1 = base1.add(limit1).add(unused1);

        // Burn shares
        _burn(msg.sender, shares);

        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");
        emit Withdraw(msg.sender, to, shares, amount0, amount1);
    }

    /// @dev Calculates proportion of liquidity from `shares`, then burns
    /// liquidity and collects owed tokens from Uniswap pool.
    function _burnLiquidityShare(
        int24 tickLower,
        int24 tickUpper,
        uint256 shares,
        address to
    ) internal returns (uint256 amount0, uint256 amount1) {
        (uint128 position, , , , ) = _position(tickLower, tickUpper);
        uint128 liquidity = _uint128Safe(uint256(position).mul(shares).div(totalSupply()));

        if (liquidity > 0) {
            (amount0, amount1) = pool.burn(tickLower, tickUpper, liquidity);
        }

        if (amount0 > 0 || amount1 > 0) {
            (amount0, amount1) = pool.collect(
                to,
                tickLower,
                tickUpper,
                _uint128Safe(amount0),
                _uint128Safe(amount1)
            );
        }
    }

    /**
     * @notice Updates vault's positions depending on how the price has moved.
     * Reverts if current price deviates too much from the TWAP, or if the
     * price is extremely high or low.
     */
    function rebalance() external override nonReentrant {
        require(msg.sender == keeper, "keeper");

        (, int24 mid, , , , , ) = pool.slot0();
        _checkMid(mid);

        int24 midFloor = _floor(mid);
        int24 midCeil = midFloor + tickSpacing;

        // Withdraw all liquidity and collect fees from Uniswap pool
        _burnAllLiquidity(baseLower, baseUpper);
        _burnAllLiquidity(limitLower, limitUpper);

        // Emit event with useful info
        uint256 balance0 = _balance0();
        uint256 balance1 = _balance1();
        emit Rebalance(mid, balance0, balance1, totalSupply());

        // Place base order on Uniswap
        _mintBaseOrder(midFloor, midCeil, balance0, balance1);

        // Place limit order on Uniswap
        _mintLimitOrder(midFloor, midCeil, _balance0(), _balance1());
    }

    function _burnAllLiquidity(int24 tickLower, int24 tickUpper)
        internal
        returns (
            uint256 owed0,
            uint256 owed1,
            uint256 collect0,
            uint256 collect1
        )
    {
        (uint128 liquidity, , , , ) = _position(tickLower, tickUpper);
        if (liquidity > 0) {
            (owed0, owed1) = pool.burn(tickLower, tickUpper, liquidity);
        }
        if (owed0 > 0 || owed1 > 0) {
            (collect0, collect1) = pool.collect(
                address(this),
                tickLower,
                tickUpper,
                type(uint128).max,
                type(uint128).max
            );
        }
    }

    /// @dev Places the base order. This is an order that's symmetric around
    /// the current price.
    function _mintBaseOrder(
        int24 midFloor,
        int24 midCeil,
        uint256 amount0,
        uint256 amount1
    ) internal {
        int24 tickLower = midFloor - baseThreshold;
        int24 tickUpper = midCeil + baseThreshold;
        uint128 liquidity = _liquidityForAmounts(tickLower, tickUpper, amount0, amount1);

        if (liquidity > 0) {
            pool.mint(
                address(this),
                tickLower,
                tickUpper,
                liquidity,
                abi.encode(address(this))
            );
        }
        (baseLower, baseUpper) = (tickLower, tickUpper);
    }

    /// @dev Places the limit order. This is an order that's either just above
    /// or just below the current price.
    function _mintLimitOrder(
        int24 midFloor,
        int24 midCeil,
        uint256 amount0,
        uint256 amount1
    ) internal {
        (int24 bidLower, int24 bidUpper) = (midFloor - limitThreshold, midFloor);
        (int24 askLower, int24 askUpper) = (midCeil, midCeil + limitThreshold);
        uint128 bidLiquidity = _liquidityForAmounts(bidLower, bidUpper, amount0, amount1);
        uint128 askLiquidity = _liquidityForAmounts(askLower, askUpper, amount0, amount1);

        // Choose the range on which more liquidity can be placed
        bool bid = bidLiquidity > askLiquidity;
        int24 tickLower = bid ? bidLower : askLower;
        int24 tickUpper = bid ? bidUpper : askUpper;
        uint128 liquidity = bid ? bidLiquidity : askLiquidity;

        if (liquidity > 0) {
            pool.mint(
                address(this),
                tickLower,
                tickUpper,
                liquidity,
                abi.encode(address(this))
            );
        }
        (limitLower, limitUpper) = (tickLower, tickUpper);
    }

    /**
     * @notice Calculates the vault's total holdings of token0 and token1 - in
     * other words, how much of each token the vault would hold if it withdrew
     * all its liquidity from Uniswap.
     */
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        (uint256 base0, uint256 base1) = _positionAmounts(baseLower, baseUpper);
        (uint256 limit0, uint256 limit1) = _positionAmounts(limitLower, limitUpper);
        total0 = _balance0().add(base0).add(limit0);
        total1 = _balance1().add(base1).add(limit1);
    }

    function _balance0() internal view returns (uint256) {
        return token0.balanceOf(address(this)).sub(fees0);
    }

    function _balance1() internal view returns (uint256) {
        return token1.balanceOf(address(this)).sub(fees1);
    }

    /// @dev Calculates amounts of token0 and token1 held in a position.
    function _positionAmounts(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 positionKey = PositionKey.compute(address(this), tickLower, tickUpper);
        (uint128 liquidity, , , uint128 tokensOwed0, uint128 tokensOwed1) =
            pool.positions(positionKey);

        (amount0, amount1) = _amountsForLiquidity(tickLower, tickUpper, liquidity);
        amount0 = amount0.add(uint256(tokensOwed0));
        amount1 = amount1.add(uint256(tokensOwed1));
    }

    /// @dev Callback for Uniswap V3 pool.
    function uniswapV3MintCallback(
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external override {
        require(msg.sender == address(pool));
        address payer = abi.decode(data, (address));

        if (payer == address(this)) {
            if (amount0 > 0) token0.safeTransfer(msg.sender, amount0);
            if (amount1 > 0) token1.safeTransfer(msg.sender, amount1);
        } else {
            if (amount0 > 0) token0.safeTransferFrom(payer, msg.sender, amount0);
            if (amount1 > 0) token1.safeTransferFrom(payer, msg.sender, amount1);
        }
    }

    function _position(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (
            uint128,
            uint256,
            uint256,
            uint128,
            uint128
        )
    {
        bytes32 positionKey = PositionKey.compute(address(this), tickLower, tickUpper);
        return pool.positions(positionKey);
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

    function _checkMid(int24 mid) internal view {
        // Check price is not too close to min/max allowed by Uniswap. In
        // practice, the price would only be this extreme if all liquidity
        // was pulled from the underlying pool.
        int24 maxThreshold = baseThreshold > limitThreshold ? baseThreshold : limitThreshold;
        require(mid > TickMath.MIN_TICK + maxThreshold + tickSpacing, "price too low");
        require(mid < TickMath.MAX_TICK - maxThreshold - tickSpacing, "price too high");

        // Check TWAP deviation. This check prevents price manipulation before
        // the rebalance and also avoids rebalancing when price has just spiked.
        int24 twap = getTwap();
        int24 deviation = mid > twap ? mid - twap : twap - mid;
        require(deviation <= maxTwapDeviation, "maxTwapDeviation");
    }

    function _checkThreshold(int24 threshold) internal view {
        require(threshold % tickSpacing == 0, "threshold not tick multiple");
        require(threshold < TickMath.MAX_TICK, "threshold too high");
        require(threshold > 0, "threshold not positive");
    }

    /// @dev Round tick down towards negative infinity towards nearest multiple
    /// of `tickSpacing`.
    function _floor(int24 tick) internal view returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }

    function _uint128Safe(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    function getTwap() public view returns (int24) {
        uint32 _twapDuration = twapDuration;
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = _twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, ) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / _twapDuration);
    }

    function collectFees(address to)
        external
        onlyGovernance
        returns (uint256 _fees0, uint256 _fees1)
    {
        (_fees0, _fees1) = (fees0, fees1);
        if (_fees0 > 0) token0.safeTransfer(to, _fees0);
        if (_fees1 > 0) token1.safeTransfer(to, _fees1);
        fees0 = 0;
        fees1 = 0;
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

    function setProtocolFee(uint256 _protocolFee) external onlyGovernance {
        require(_protocolFee < 1e6, "protocolFee");
        protocolFee = _protocolFee;
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
