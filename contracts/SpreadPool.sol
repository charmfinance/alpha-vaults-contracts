// SPDX-License-Identifier: Unlicense

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";


/**
 * @title   Spread Pool
 */
contract SpreadPool is ERC20, Ownable, ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;
    using SafeMath for int24;
    using SafeMath for uint256;
    using SafeMath for int56;

    IERC20 public token0;
    IERC20 public token1;
    uint24 public fee;

    int24 public baseWidth;
    int24 public rebalanceWidth;
    uint32 public twapDuration;
    uint256 withdrawFee;
    uint256 performanceFee;
    bool public depositPaused;
    bool public withdrawPaused;
    bool public finalized;

    uint256 public basePositionId;
    uint256 public rebalancePositionId;


    constructor(string memory name, string memory symbol, address _token0, address _token1, uint24 _fee) public ERC20(name, symbol
    ) {
        token0 = IERC20(_token0);
        token1 = IERC20(_token1);
        fee = _fee;
    }

    function deposit(uint256 amount, address recipient) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(!depositPaused, "Paused");
        uint256 _totalSupply = totalSupply();
        if (_totalSupply > 0) {
            amount0 = totalBalance0().mul(amount).div(_totalSupply);
            amount1 = totalBalance1().mul(amount).div(_totalSupply);
        } else {
            // TODO calculate initial amounts from uniswap price
        }

        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        _mint(recipient, amount);
    }

    function withdraw(uint256 amount, address recipient) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        require(!withdrawPaused, "Paused");
        uint256 _totalSupply = totalSupply();
        amount0 = totalBalance0().mul(amount).div(_totalSupply);
        amount1 = totalBalance1().mul(amount).div(_totalSupply);

        amount0 = amount0.sub(amount0.mul(withdrawFee).div(1e6);
        amount1 = amount1.sub(amount1.mul(withdrawFee).div(1e6);
        require(amount0 <= token0.balanceof(address(this)), "Not enough balance 0");
        require(amount1 <= token1.balanceof(address(this)), "Not enough balance 1");

        burn(msg.sender, amount);
        token0.safeTransfer(msg.sender, amount0);
        token1.safeTransfer(msg.sender, amount1);
    }

    function update() external onlyOwner {
        // TODO remove liquidity

        // TODO add back base position


        // TODO add rebalancing position

        // TODO collect fees
    }

    /**
     * Get twap price from oracle in ticks
     */
    function getPriceInTicks() public view returns (int56) {
        uint32 secondsAgos[2] = [twapDuration, 0];
        (int56[] tickCumulatives, ) = uniswapV3Pool.observe(secondsAgos);
        return tickCumulatives[1].sub(tickCumulatives[0]);
    }

    function totalBalance0() public view returns (uint256) {
        // TODO add balances in positions
        return token0.balanceOf(address(this));
    }

    function totalBalance1() public view returns (uint256) {
        // TODO add balances in positions
        return token1.balanceOf(address(this));
    }

    /**
     * @param _baseWidth Target width of base liquidity in ticks or basis points
     */
    function setBaseWidth(int24 _baseWidth) external onlyOwner {
        baseWidth = _baseWidth;
    }

    /**
     * @param _rebalanceWidth Target width of rebalance liquidity in ticks or basis points
     */
    function setRebalanceWidth(int24 _rebalanceWidth) external onlyOwner {
        rebalanceWidth = _rebalanceWidth;
    }

    /**
     * @param _twapDuration Duration of twap price fetched from oracle in seconds
     */
    function setTwapDuration(uint32 _twapDuration) external onlyOwner {
        twapDuration = _twapDuration;
    }

    /**
     * @param _withdrawFee Fee charged on withdrawal multiplied by 1e6
     */
    function setWithdrawFee(bool _withdrawFee) external onlyOwner {
        withdrawFee = _withdrawFee;
    }

    /**
     * @param _performanceFee Fee charged when collecting Uniswap fees
     */
    function setPerformanceFee(bool _performanceFee) external onlyOwner {
        performanceFee = _performanceFee;
    }

    // TODO think more about what powers are needed

    function setDepositPaused(bool paused) external onlyOwner {
        depositPaused = paused;
    }

    function setWithdrawPaused(bool paused) external onlyOwner {
        withdrawPaused = paused;
    }

    /**
     *
     */
    function liquidate(uint256 amount, address recipient) external nonReentrant onlyOwner {

        // TODO decide if need this, see what yearn vaults do
    }

    /**
     * @notice Renounce emergency withdraw powers
     */
    function finalize() external onlyOwner {
        require(!finalized, "Already finalized");
        finalized = true;
    }

    /**
     * @notice Transfer all ETH to owner in case of emergency. Cannot be called
     * if already finalized
     */
    function emergencyWithdraw() external {
        require(msg.sender == owner() || msg.sender == guardian, "Must be owner or guardian");
        require(!finalized, "Finalized");
        payable(owner()).transfer(address(this).balance);
    }
}



/**

https://docs.uniswap.org/

struct MintParams {
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 amount;
    uint256 amount0Max;
    uint256 amount1Max;
    address recipient;
    uint256 deadline;
}
*/
