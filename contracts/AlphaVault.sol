// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/base/Multicall.sol";
import "@uniswap/v3-periphery/contracts/base/SelfPermit.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import "@uniswap/v3-periphery/contracts/libraries/PositionKey.sol";

import "../interfaces/IVault.sol";

/**
 * @title   Alpha Vault
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
contract AlphaVault is
    IVault,
    IUniswapV3MintCallback,
    Multicall,
    ERC20,
    ReentrancyGuard,
    SelfPermit
{
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    bytes32 public version = "1.1";

    IUniswapV3Pool public pool;
    IERC20 public token0;
    IERC20 public token1;
    uint24 public fee;
    int24 public tickSpacing;

    uint256 public protocolFee;
    uint256 public maxTotalSupply;
    address public governance;
    address public pendingGovernance;
    bool public finalized;
    address public strategy;

    int24 public baseLower;
    int24 public baseUpper;
    int24 public limitLower;
    int24 public limitUpper;
    uint256 public protocolFees0;
    uint256 public protocolFees1;

    /**
     * @param _pool Underlying Uniswap V3 pool
     * @param _protocolFee Fee on deposits expressed as multiple of 1e-6
     * @param _maxTotalSupply Pause deposits if total supply exceeds this
     */
    constructor(
        address _pool,
        uint256 _protocolFee,
        uint256 _maxTotalSupply
    ) ERC20("Alpha Vault", "AV") {
        pool = IUniswapV3Pool(_pool);
        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        protocolFee = _protocolFee;
        maxTotalSupply = _maxTotalSupply;
        governance = msg.sender;

        require(_protocolFee < 1e6, "protocolFee");
    }

    /**
     * @notice Deposit tokens in proportion to the vault's holdings.
     * @dev Note it's not possible for the user to manipulate price to deposit
     * cheaper, as the value of the range orders would always be increased.
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
        require(amount0Desired > 0 || amount1Desired > 0, "amounts");
        require(to != address(0) && to != address(this), "to");

        // Do a zero-burn to poke the Uniswap pool so it updates fees earned
        if (_positionLiquidity(baseLower, baseUpper) > 0) {
            pool.burn(baseLower, baseUpper, 0);
        }
        if (_positionLiquidity(limitLower, limitUpper) > 0) {
            pool.burn(limitLower, limitUpper, 0);
        }

        (shares, amount0, amount1) = _calcSharesAndAmounts(amount0Desired, amount1Desired);
        require(shares > 0, "shares");
        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");

        // Mint shares to recipient
        _mint(to, shares);
        emit Deposit(msg.sender, to, shares, amount0, amount1);
        require(totalSupply() <= maxTotalSupply, "maxTotalSupply");

        // Transfer in tokens from sender
        if (amount0 > 0) token0.safeTransferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) token1.safeTransferFrom(msg.sender, address(this), amount1);
    }

    // @dev Calculates the largest possible `amount0` and `amount1` such that
    // they're in the same proportion as `total0` and `total1`, but not greater
    // than `amount0Desired` and `amount1Desired` respectively.
    function _calcSharesAndAmounts(uint256 amount0Desired, uint256 amount1Desired)
        internal
        view
        returns (
            uint256 shares,
            uint256 amount0,
            uint256 amount1
        )
    {
        uint256 totalSupply = totalSupply();
        (uint256 total0, uint256 total1) = getTotalAmounts();
        if (totalSupply == 0) {
            // For first deposit, just use the input amounts desired
            amount0 = amount0Desired;
            amount1 = amount1Desired;
            shares = Math.max(amount0, amount1);
        } else if (total0 == 0) {
            amount1 = amount1Desired;
            shares = amount1.mul(totalSupply).div(total1);
        } else if (total1 == 0) {
            amount0 = amount0Desired;
            shares = amount0.mul(totalSupply).div(total0);
        } else {
            uint256 cross = Math.min(amount0Desired.mul(total1), amount1Desired.mul(total0));
            require(cross > 0, "cross");

            amount0 = cross.sub(1).div(total1).add(1); // round up
            amount1 = cross.sub(1).div(total0).add(1); // round up
            shares = cross.mul(totalSupply).div(total0).div(total1);
        }
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
        require(to != address(0) && to != address(this), "to");

        // Withdraw proportion of liquidity from Uniswap pool and send
        // resulting tokens to recipient directly
        (uint256 baseAmount0, uint256 baseAmount1) =
            _burnLiquidityShare(baseLower, baseUpper, shares, to);
        (uint256 limitAmount0, uint256 limitAmount1) =
            _burnLiquidityShare(limitLower, limitUpper, shares, to);

        // Also transfer tokens proportional to unused balances
        uint256 totalSupply = totalSupply();
        uint256 unusedAmount0 = _balance0().mul(shares).div(totalSupply);
        uint256 unusedAmount1 = _balance1().mul(shares).div(totalSupply);
        if (unusedAmount0 > 0) token0.safeTransfer(to, unusedAmount0);
        if (unusedAmount1 > 0) token1.safeTransfer(to, unusedAmount1);

        // Sum up total amounts sent to recipient
        amount0 = baseAmount0.add(limitAmount0).add(unusedAmount0);
        amount1 = baseAmount1.add(limitAmount1).add(unusedAmount1);
        require(amount0 >= amount0Min, "amount0Min");
        require(amount1 >= amount1Min, "amount1Min");

        // Burn shares
        _burn(msg.sender, shares);
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
        uint256 position = uint256(_positionLiquidity(tickLower, tickUpper));
        uint128 liquidity = _toUint128(position.mul(shares).div(totalSupply()));

        if (liquidity > 0) {
            (amount0, amount1) = pool.burn(tickLower, tickUpper, liquidity);

            if (amount0 > 0 || amount1 > 0) {
                (amount0, amount1) = pool.collect(
                    to,
                    tickLower,
                    tickUpper,
                    _toUint128(amount0),
                    _toUint128(amount1)
                );
            }
        }
    }

    /**
     * @notice Updates vault's positions depending on how the price has moved.
     * Reverts if current price deviates too much from the TWAP, or if the
     * price is extremely high or low.
     */
    function rebalance(
        int24 _baseLower,
        int24 _baseUpper,
        int24 _bidLower,
        int24 _bidUpper,
        int24 _askLower,
        int24 _askUpper
    ) external nonReentrant {
        require(msg.sender == strategy, "strategy");

        // Withdraw all liquidity and collect fees from Uniswap pool
        _burnAllLiquidity(baseLower, baseUpper);
        _burnAllLiquidity(limitLower, limitUpper);

        // Emit event with useful info
        uint256 balance0 = _balance0();
        uint256 balance1 = _balance1();
        (, int24 mid, , , , , ) = pool.slot0();
        emit Snapshot(mid, balance0, balance1, totalSupply());

        // Place base order on Uniswap
        uint128 liquidity = _liquidityForAmounts(_baseLower, _baseUpper, balance0, balance1);
        _mintLiquidity(_baseLower, _baseUpper, liquidity);
        (baseLower, baseUpper) = (_baseLower, _baseUpper);

        balance0 = _balance0();
        balance1 = _balance1();
        uint128 bidLiquidity = _liquidityForAmounts(_bidLower, _bidUpper, balance0, balance1);
        uint128 askLiquidity = _liquidityForAmounts(_askLower, _askUpper, balance0, balance1);

        // Place limit order on Uniswap. This is an order that's completely
        // on one side of the current price
        if (bidLiquidity > askLiquidity) {
            _mintLiquidity(_bidLower, _bidUpper, bidLiquidity);
            (limitLower, limitUpper) = (_bidLower, _bidUpper);
        } else {
            _mintLiquidity(_askLower, _askUpper, askLiquidity);
            (limitLower, limitUpper) = (_askLower, _askUpper);
        }
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
        uint128 liquidity = _positionLiquidity(tickLower, tickUpper);
        if (liquidity > 0) {
            (owed0, owed1) = pool.burn(tickLower, tickUpper, liquidity);
        }
        (collect0, collect1) = pool.collect(
            address(this),
            tickLower,
            tickUpper,
            type(uint128).max,
            type(uint128).max
        );
        uint256 fees0 = collect0.sub(owed0);
        uint256 fees1 = collect1.sub(owed1);

        uint256 _protocolFee = protocolFee;
        uint256 _protocolFees0 = fees0.mul(_protocolFee).div(1e6);
        uint256 _protocolFees1 = fees1.mul(_protocolFee).div(1e6);

        protocolFees0 = protocolFees0.add(_protocolFees0);
        protocolFees1 = protocolFees1.add(_protocolFees1);
        emit CollectFees(fees0, fees1, _protocolFees0, _protocolFees1);
    }

    function _mintLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal {
        if (tickLower < tickUpper && liquidity > 0) {
            pool.mint(
                address(this),
                tickLower,
                tickUpper,
                liquidity,
                abi.encode(address(this))
            );
        }
    }

    /**
     * @notice Calculates the vault's total holdings of token0 and token1 - in
     * other words, how much of each token the vault would hold if it withdrew
     * all its liquidity from Uniswap.
     */
    function getTotalAmounts() public view override returns (uint256 total0, uint256 total1) {
        (uint256 baseAmount0, uint256 baseAmount1) = _positionAmounts(baseLower, baseUpper);
        (uint256 limitAmount0, uint256 limitAmount1) = _positionAmounts(limitLower, limitUpper);
        total0 = _balance0().add(baseAmount0).add(limitAmount0);
        total1 = _balance1().add(baseAmount1).add(limitAmount1);
    }

    /// @dev Calculates amount of liquidity in vault's position.
    function _positionLiquidity(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint128 liquidity)
    {
        bytes32 positionKey = PositionKey.compute(address(this), tickLower, tickUpper);
        (liquidity, , , , ) = pool.positions(positionKey);
    }

    /// @dev Calculates amounts of token0 and token1 held in vault's position.
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

    function _balance0() internal view returns (uint256) {
        return token0.balanceOf(address(this)).sub(protocolFees0);
    }

    function _balance1() internal view returns (uint256) {
        return token1.balanceOf(address(this)).sub(protocolFees1);
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

    function _toUint128(uint256 x) internal pure returns (uint128) {
        assert(x <= type(uint128).max);
        return uint128(x);
    }

    function collectProtocol(
        uint256 amount0,
        uint256 amount1,
        address to
    ) external onlyGovernance {
        protocolFees0 = protocolFees0.sub(amount0);
        protocolFees1 = protocolFees1.sub(amount1);
        if (amount0 > 0) token0.safeTransfer(to, amount0);
        if (amount1 > 0) token1.safeTransfer(to, amount1);
    }

    function setStrategy(address _strategy) external onlyGovernance {
        strategy = _strategy;
    }

    function setProtocolFee(uint256 _protocolFee) external onlyGovernance {
        require(_protocolFee < 1e6, "protocolFee");
        protocolFee = _protocolFee;
    }

    function setMaxTotalSupply(uint256 _maxTotalSupply) external onlyGovernance {
        maxTotalSupply = _maxTotalSupply;
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
