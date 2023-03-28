// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {sc4626} from "../sc4626.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import "../errors/scWETHErrors.sol";

contract scWETH is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event SlippageToleranceUpdated(address indexed user, uint256 newSlippageTolerance);
    event ExchangeProxyAddressUpdated(address indexed user, address newAddress);
    event TargetLtvRatioUpdated(address indexed user, uint256 newTargetLtv);
    event Harvest(uint256 profitSinceLastHarvest, uint256 performanceFee);

    // interest rate mode at which to borrow or repay
    uint256 public constant WAD = 1e18;
    uint256 public constant INTEREST_RATE_MODE = 2;
    uint8 public constant EMODE_ID = 1;
    IPool public constant aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    // aToken is a rebasing token and pegged 1:1 to the underlying
    IAToken public constant aToken = IAToken(0x0B925eD163218f6662a35e0f0371Ac234f9E9371);
    ERC20 public constant variableDebtToken = ERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);
    // Curve pool for ETH-stETH
    ICurvePool public constant curvePool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    // Lido staking contract (stETH)
    ILido public constant stEth = ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IwstETH public constant wstETH = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    WETH public constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    // Balancer vault for flashloans
    IVault public constant balancerVault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // Chainlink pricefeed (stETH -> ETH)
    AggregatorV3Interface public stEThToEthPriceFeed = AggregatorV3Interface(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);

    // 0x swap router
    address public xrouter = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // total invested during last harvest/rebalance
    uint256 public totalInvested;

    // total profit generated for this vault
    uint256 public totalProfit;

    // the target ltv ratio at which we actually borrow (<= maxLtv)
    uint256 public targetLtv;

    // slippage for curve swaps
    uint256 public slippageTolerance;

    constructor(address _admin, uint256 _targetLtv, uint256 _slippageTolerance)
        sc4626(_admin, ERC20(address(weth)), "Sandclock WETH Vault", "scWETH")
    {
        if (_admin == address(0)) revert ZeroAddress();
        if (_slippageTolerance > WAD) revert InvalidSlippageTolerance();

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(stEth)).safeApprove(address(curvePool), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(address(aavePool), type(uint256).max);
        ERC20(address(weth)).safeApprove(address(aavePool), type(uint256).max);

        // set e-mode on aave-v3 for increased borrowing capacity to 90% of collateral
        aavePool.setUserEMode(EMODE_ID);

        if (_targetLtv >= getMaxLtv()) revert InvalidTargetLtv();

        targetLtv = _targetLtv;
        slippageTolerance = _slippageTolerance;
    }

    /// @notice set the slippage tolerance for curve swaps
    /// @param newSlippageTolerance the new slippage tolerance
    /// @dev slippage tolerance is a number between 0 and 1e18
    function setSlippageTolerance(uint256 newSlippageTolerance) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSlippageTolerance > WAD) revert InvalidSlippageTolerance();
        slippageTolerance = newSlippageTolerance;
        emit SlippageToleranceUpdated(msg.sender, newSlippageTolerance);
    }

    /// @notice set the address of the exchange proxy for the 0x router
    /// @param newAddress the new address of the 0x router
    function setExchangeProxyAddress(address newAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAddress == address(0)) revert ZeroAddress();
        xrouter = newAddress;
        emit ExchangeProxyAddressUpdated(msg.sender, newAddress);
    }

    /// @notice set stEThToEthPriceFeed address
    /// @param newAddress the new address of the stEThToEthPriceFeed
    function setStEThToEthPriceFeed(address newAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAddress == address(0)) revert ZeroAddress();
        stEThToEthPriceFeed = AggregatorV3Interface(newAddress);
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    /// @notice harvest profits and rebalance the position by investing profits back into the strategy
    /// @dev reduces the getLtv() back to the target ltv
    /// @dev also mints performance fee tokens to the treasury
    function harvest() external onlyRole(KEEPER_ROLE) {
        // store the old total
        uint256 oldTotalInvested = totalInvested;

        // reinvest
        _rebalancePosition();

        totalInvested = totalAssets();

        if (totalInvested > oldTotalInvested) {
            // profit since last harvest, zero if there was a loss
            uint256 profit = totalInvested - oldTotalInvested;
            totalProfit += profit;

            uint256 fee = profit.mulWadDown(performanceFee);

            // mint equivalent amount of tokens to the performance fee beneficiary ie the treasury
            _mint(treasury, fee.mulDivDown(WAD, convertToAssets(WAD)));

            emit Harvest(profit, fee);
        }
    }

    /// @notice increase/decrease the target ltv used on borrows
    /// @param newTargetLtv the new target ltv
    /// @dev the new target ltv must be less than the max ltv allowed on aave
    function changeLeverage(uint256 newTargetLtv) public onlyRole(KEEPER_ROLE) {
        if (newTargetLtv >= getMaxLtv()) revert InvalidTargetLtv();

        targetLtv = newTargetLtv;
        emit TargetLtvRatioUpdated(msg.sender, newTargetLtv);

        _rebalancePosition();
    }

    /// @notice deposit all available funds into the strategy
    /// @dev separate to save gas for users depositing
    function depositIntoStrategy() external onlyRole(KEEPER_ROLE) {
        _rebalancePosition();
    }

    /// @notice withdraw funds from the strategy into the vault
    /// @param amount : amount of assets to withdraw into the vault
    function withdrawToVault(uint256 amount) external onlyRole(KEEPER_ROLE) {
        _withdrawToVault(amount);
    }

    //////////////////// VIEW METHODS //////////////////////////

    /// @notice returns the total assets (WETH) held by the strategy
    function totalAssets() public view override returns (uint256 assets) {
        // value of the supplied collateral in eth terms using chainlink oracle
        assets = totalCollateralSupplied();

        // subtract the debt
        assets -= totalDebt();

        // add float
        assets += asset.balanceOf(address(this));
    }

    /// @notice returns the total wstETH supplied as collateral (in ETH)
    function totalCollateralSupplied() public view returns (uint256) {
        return _wstEthToEth(aToken.balanceOf(address(this)));
    }

    /// @notice returns the total ETH borrowed
    function totalDebt() public view returns (uint256) {
        return variableDebtToken.balanceOf(address(this));
    }

    /// @notice returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        uint256 coll = totalCollateralSupplied();
        return coll > 0 ? coll.divWadUp(coll - totalDebt()) : 0;
    }

    /// @notice returns the net LTV at which we have borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256 ltv) {
        uint256 collateral = totalCollateralSupplied();
        if (collateral > 0) {
            // totalDebt / totalSupplied
            ltv = totalDebt().divWadUp(collateral);
        }
    }

    /// @notice returns the max loan to value(ltv) ratio for borrowing eth on Aavev3 with wsteth as collateral for the flashloan (1e18 = 100%)
    function getMaxLtv() public view returns (uint256) {
        return uint256(aavePool.getEModeCategoryData(EMODE_ID).ltv) * 1e14;
    }

    //////////////////// EXTERNAL METHODS //////////////////////////

    /// @notice helper method to directly deposit ETH instead of weth
    function deposit(address receiver) external payable returns (uint256 shares) {
        uint256 assets = msg.value;

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // wrap eth
        weth.deposit{value: assets}();

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        uint256 balance = asset.balanceOf(address(this));

        if (assets > balance) {
            assets = balance;
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    function withdraw(uint256, address, address) public virtual override returns (uint256) {
        revert PleaseUseRedeemMethod();
    }

    /// @dev called after the flashLoan on _rebalancePosition
    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        // the amount flashloaned
        uint256 flashLoanAmount = amounts[0];

        // decode user data
        (bool isDeposit, uint256 amount) = abi.decode(userData, (bool, uint256));

        amount += flashLoanAmount;

        // if flashloan received as part of a deposit
        if (isDeposit) {
            // unwrap eth
            weth.withdraw(amount);

            // stake to lido / eth => stETH
            stEth.submit{value: amount}(address(0x00));

            // wrap stETH
            wstETH.wrap(stEth.balanceOf(address(this)));

            //add wstETH liquidity on aave-v3
            aavePool.supply(address(wstETH), wstETH.balanceOf(address(this)), address(this), 0);

            //borrow enough weth from aave-v3 to payback flashloan
            aavePool.borrow(address(weth), flashLoanAmount, INTEREST_RATE_MODE, 0, address(this));
        }
        // if flashloan received as part of a withdrawal
        else {
            // repay debt + withdraw collateral
            if (flashLoanAmount >= totalDebt()) {
                aavePool.repay(address(weth), type(uint256).max, INTEREST_RATE_MODE, address(this));
                aavePool.withdraw(address(wstETH), type(uint256).max, address(this));
            } else {
                aavePool.repay(address(weth), flashLoanAmount, INTEREST_RATE_MODE, address(this));
                aavePool.withdraw(address(wstETH), _ethToWstEth(amount), address(this));
            }

            // unwrap wstETH
            uint256 stEthAmount = wstETH.unwrap(wstETH.balanceOf(address(this)));

            // stETH to eth
            curvePool.exchange(1, 0, stEthAmount, _stEthToEth(stEthAmount).mulWadDown(slippageTolerance));

            // wrap eth
            weth.deposit{value: address(this).balance}();
        }

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    function _rebalancePosition() internal {
        // storage loads
        uint256 amount = asset.balanceOf(address(this));
        uint256 ltv = targetLtv;
        uint256 debt = totalDebt();
        uint256 collateral = totalCollateralSupplied();

        uint256 target = ltv.mulWadDown(amount + collateral);

        // whether we should deposit or withdraw
        bool isDeposit = target > debt;

        // calculate the flashloan amount needed
        uint256 flashLoanAmount = (isDeposit ? target - debt : debt - target).divWadDown(WAD - ltv);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // needed otherwise counted as profit during harvest
        totalInvested += amount;

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(isDeposit, amount));
    }

    function _withdrawToVault(uint256 amount) internal {
        uint256 debt = totalDebt();
        uint256 collateral = totalCollateralSupplied();

        uint256 flashLoanAmount = amount.mulDivDown(debt, collateral - debt);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(false, amount));
    }

    function _stEthToEth(uint256 stEthAmount) internal view returns (uint256 ethAmount) {
        if (stEthAmount > 0) {
            // stEth to eth
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();
            ethAmount = stEthAmount.mulWadDown(uint256(price));
        }
    }

    function _wstEthToEth(uint256 wstEthAmount) internal view returns (uint256 ethAmount) {
        // wstETh to stEth using exchangeRate
        uint256 stEthAmount = wstETH.getStETHByWstETH(wstEthAmount);
        ethAmount = _stEthToEth(stEthAmount);
    }

    function _ethToWstEth(uint256 ethAmount) internal view returns (uint256 wstEthAmount) {
        if (ethAmount > 0) {
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

            // eth to stEth
            uint256 stEthAmount = ethAmount.divWadDown(uint256(price));

            // stEth to wstEth
            wstEthAmount = wstETH.getWstETHByStETH(stEthAmount);
        }
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        uint256 float = asset.balanceOf(address(this));
        if (assets <= float) {
            return;
        }

        uint256 missing = (assets - float);

        // needed otherwise counted as loss during harvest
        totalInvested -= missing;

        _withdrawToVault(missing);
    }
}