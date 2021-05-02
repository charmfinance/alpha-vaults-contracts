// SPDX-License-Identifier: Unlicense

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/drafts/ERC20Permit.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
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

// TODO: change constructor order
// TODO: fix flipping
// TODO: fix initial mint
// TODO: return amounts from burn
// TODO: choose name and symbol
// TODO: events
// TODO: fuzzing
// TODO: add twap check

/**
 * @title   Base Vault
 * @notice  A vault that provides liquidity on Uniswap V3 on behalf of users
 * @dev     To use, inherit from this contract and override `_baseRange()`
 *          and `_skewRange()`. These methods should return the tick ranges
 *          for the vault's range orders.
 */
abstract contract BaseVault is
    IUniswapV3MintCallback,
    Multicall,
    SelfPermit,
    ERC20Permit,
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

    uint32 public twapDuration;
    uint256 public refreshCooldown;
    uint256 public totalSupplyCap;

    Range public baseRange;
    Range public skewRange;

    address public governance;
    address public pendingGovernance;
    address public keeper;
    uint256 public lastUpdate;

    /**
     * @param _pool Underlying Uniswap V3 pool
     * @param _refreshCooldown How much time needs to pass between `refresh()`
     * calls in seconds
     * @param _totalSupplyCap Users can't deposit if total supply would exceed
     * this limit. Value of 0 means no cap.
     */
    constructor(
        address _pool,
        uint32 _twapDuration,
        uint256 _refreshCooldown,
        uint256 _totalSupplyCap
    ) ERC20("Passive Rebalance Vault", "PRV") ERC20Permit("Passive Rebalance Vault") {
        require(_pool != address(0));
        pool = IUniswapV3Pool(_pool);

        token0 = IERC20(pool.token0());
        token1 = IERC20(pool.token1());
        fee = pool.fee();
        tickSpacing = pool.tickSpacing();

        twapDuration = _twapDuration;
        refreshCooldown = _refreshCooldown;
        totalSupplyCap = _totalSupplyCap;

        governance = msg.sender;
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
        maxAmount0 = maxAmount0 >= 2 ? maxAmount0 - 2 : maxAmount0;
        maxAmount1 = maxAmount1 >= 2 ? maxAmount1 - 2 : maxAmount1;

        (uint256 total0, uint256 total1) = getTotalAmounts();
        assert(total0 > 0 || total1 > 0);

        // Set shares to the maximum possible value that implies amounts not
        // greater than `maxAmount0` and `maxAmount1`
        if (maxAmount0.mul(total1) < maxAmount1.mul(total0) || total1 == 0) {
            shares = maxAmount0.mul(_totalSupply).div(total0);
        } else {
            shares = maxAmount1.mul(_totalSupply).div(total1);
        }
        require(shares > 0, "shares");

        // Deposit liquidity into Uniswap
        uint128 baseLiquidity = _liquidityForShares(baseRange, shares);
        uint128 skewLiquidity = _liquidityForShares(skewRange, shares);
        _mintLiquidity(baseRange, baseLiquidity, msg.sender);
        _mintLiquidity(skewRange, skewLiquidity, msg.sender);

        // Mint shares
        _mint(to, shares);
        require(totalSupplyCap == 0 || totalSupply() <= totalSupplyCap, "totalSupplyCap");
    }

    function _initialMint(
        uint256 maxAmount0,
        uint256 maxAmount1,
        address to
    ) internal returns (uint256 shares) {
        shares = _liquidityForAmounts(baseRange, maxAmount0, maxAmount1);
        require(shares > 0, "shares");
        require(shares < type(uint128).max, "shares");

        // Deposit liquidity into Uniswap. The initial mint only places an
        // order in the base range and ignores the skew range.
        _mintLiquidity(baseRange, uint128(shares), msg.sender);

        // Mint shares
        _mint(to, shares);
        require(totalSupplyCap == 0 || totalSupply() <= totalSupplyCap, "totalSupplyCap");
    }

    function burn(uint256 shares, address to) external nonReentrant {
        require(shares > 0, "shares");
        require(to != address(0), "to");

        // Withdraw liquidity from Uniswap
        uint128 baseLiquidity = _liquidityForShares(baseRange, shares);
        uint128 skewLiquidity = _liquidityForShares(skewRange, shares);
        _burnLiquidity(baseRange, baseLiquidity, to, false);
        _burnLiquidity(skewRange, skewLiquidity, to, false);

        // Burn shares
        _burn(msg.sender, shares);
    }

    function refresh() external {
        require(keeper == address(0) || msg.sender == keeper, "keeper");
        require(block.timestamp >= lastUpdate.add(refreshCooldown), "cooldown");
        lastUpdate = block.timestamp;

        // TODO: check twap matches

        // Withdraw all liquidity from Uniswap
        _burnLiquidity(baseRange, _deposited(baseRange), address(this), true);
        _burnLiquidity(skewRange, _deposited(skewRange), address(this), true);

        // Update base range and place order
        _updateBaseRange();
        _mintLiquidity(baseRange, _maxLiquidity(baseRange), address(this));

        // Update skew range and place order
        _updateSkewRange();
        _mintLiquidity(skewRange, _maxLiquidity(skewRange), address(this));

        // Check base and skew ranges aren't the same, otherwise
        // calculations would fail elsewhere
        assert(baseRange.lower != skewRange.lower || baseRange.upper != skewRange.upper);
    }

    function _mintLiquidity(
        Range memory range,
        uint128 liquidity,
        address payer
    ) internal {
        if (liquidity == 0) {
            return;
        }
        pool.mint(address(this), range.lower, range.upper, liquidity, abi.encode(payer));
    }

    function _burnLiquidity(
        Range memory range,
        uint128 liquidity,
        address to,
        bool collectAll
    ) internal {
        if (liquidity == 0) {
            return;
        }

        // Burn liquidity
        (uint256 amount0, uint256 amount1) =
            pool.burn(range.lower, range.upper, liquidity);

        // Collect amount owed
        uint128 collect0 = collectAll ? type(uint128).max : uint128(amount0);
        uint128 collect1 = collectAll ? type(uint128).max : uint128(amount1);
        if (collect0 > 0 || collect1 > 0) {
            pool.collect(to, range.lower, range.upper, collect0, collect1);
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
     * @notice Calculates total holdings of `token0` and `token1`, i.e. how
     * much this vault would hold if it withdrew all its liquidity.
     */
    function getTotalAmounts() public view returns (uint256, uint256) {
        (uint256 base0, uint256 base1) =
            _amountsForLiquidity(baseRange, _deposited(baseRange));
        (uint256 skew0, uint256 skew1) =
            _amountsForLiquidity(skewRange, _deposited(skewRange));

        return (
            token0.balanceOf(address(this)).add(base0).add(skew0),
            token1.balanceOf(address(this)).add(base1).add(skew1)
        );
    }

    /// @dev Convert shares into amount of liquidity
    function _liquidityForShares(Range memory range, uint256 shares)
        internal
        view
        returns (uint128)
    {
        // TODO check overflow
        return uint128(uint256(_deposited(range)).mul(shares).div(totalSupply()));
    }

    /// @dev Amount of liquidity deposited by vault into Uniswap V3 pool for a
    /// certain range
    function _deposited(Range memory range) internal view returns (uint128 liquidity) {
        bytes32 positionKey =
            keccak256(abi.encodePacked(address(this), range.lower, range.upper));
        (liquidity, , , , ) = pool.positions(positionKey);
    }

    /// @dev Maximum liquidity that can deposited in `range` by vault given
    /// its balances of `token0` and `token1`
    function _maxLiquidity(Range memory range) internal view returns (uint128) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        return _liquidityForAmounts(range, balance0, balance1);
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

    function _amountsForLiquidity(Range memory range, uint128 liquidity)
        internal
        view
        returns (uint256, uint256)
    {
        return
            LiquidityAmounts.getAmountsForLiquidity(
                _sqrtRatioX96(),
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
        return
            LiquidityAmounts.getLiquidityForAmounts(
                _sqrtRatioX96(),
                TickMath.getSqrtRatioAtTick(range.lower),
                TickMath.getSqrtRatioAtTick(range.upper),
                amount0,
                amount1
            );
    }

    /// @dev Current Uniswap price in the form of sqrt(price) * 2^96
    function _sqrtRatioX96() internal view returns (uint160 sqrtRatioX96) {
        (sqrtRatioX96, , , , , , ) = pool.slot0();
    }

    function _getTwap() internal view returns (int24) {
        uint32[] memory secondsAgo = new uint32[](2);
        secondsAgo[0] = twapDuration;
        secondsAgo[1] = 0;

        (int56[] memory tickCumulatives, uint160[] memory _) = pool.observe(secondsAgo);
        return int24((tickCumulatives[1] - tickCumulatives[0]) / twapDuration);
    }

    function _updateBaseRange() internal {
        Range memory range = _baseRange();
        baseRange = Range(range.lower, range.upper);
    }

    function _updateSkewRange() internal {
        Range memory range = _skewRange();
        skewRange = Range(range.lower, range.upper);
    }

    function _baseRange() internal virtual returns (Range memory);

    function _skewRange() internal virtual returns (Range memory);

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
