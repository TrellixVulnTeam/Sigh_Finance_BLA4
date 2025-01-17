pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {SafeMath} from '../../dependencies/openzeppelin/contracts/SafeMath.sol';
import {IERC20} from '../../dependencies/openzeppelin/contracts/IERC20.sol';
import {SafeERC20} from '../../dependencies/openzeppelin/contracts/SafeERC20.sol';
import {Address} from '../../dependencies/openzeppelin/contracts/Address.sol';

import {IGlobalAddressesProvider} from '../../interfaces/IGlobalAddressesProvider.sol';
import {IAToken} from '../../interfaces/IAToken.sol';
import {IVariableDebtToken} from '../../interfaces/IVariableDebtToken.sol';
import {IPriceOracleGetter} from '../../interfaces/IPriceOracleGetter.sol';
import {IStableDebtToken} from '../../interfaces/IStableDebtToken.sol';
import {ILendingPool} from '../../interfaces/ILendingPool.sol';

import {VersionedInitializable} from '../libraries/aave-upgradeability/VersionedInitializable.sol';
import {Helpers} from '../libraries/helpers/Helpers.sol';
import {Errors} from '../libraries/helpers/Errors.sol';
import {WadRayMath} from '../libraries/math/WadRayMath.sol';
import {PercentageMath} from '../libraries/math/PercentageMath.sol';
import {InstrumentReserveLogic} from '../libraries/logic/InstrumentReserveLogic.sol';
import {GenericLogic} from '../libraries/logic/GenericLogic.sol';
import {ValidationLogic} from '../libraries/logic/ValidationLogic.sol';
import {InstrumentConfiguration} from '../libraries/configuration/InstrumentConfiguration.sol';
import {UserConfiguration} from '../libraries/configuration/UserConfiguration.sol';
import {DataTypes} from '../libraries/types/DataTypes.sol';

import {IFlashLoanReceiver} from '../../flashloan/interfaces/IFlashLoanReceiver.sol';
import {LendingPoolStorage} from './LendingPoolStorage.sol';

/**
* @title LendingPool contract (Created by Aave, modified by SIGH Finance)
* @notice Implements the actions of the LendingPool, and exposes accessory methods to fetch the users and financial instruments data
 * @dev Main point of interaction with an Aave protocol's market
 * - Users can:
 *   # Deposit
 *   # Withdraw
 *   # Borrow
 *   # Repay
 *   # Swap their loans between variable and stable rate
 *   # Enable/disable their deposits as collateral rebalance stable rate borrow positions
 *   # Liquidate positions
 *   # Execute Flash Loans
 * - To be covered by a proxy contract, owned by the LendingPoolAddressesProvider of the specific market
 * - All admin functions are callable by the LendingPoolConfigurator contract defined also in the
 *   LendingPoolAddressesProvider
* @author Aave, SIGH Finance
 **/

contract LendingPool is ILendingPool, LendingPoolStorage, VersionedInitializable {

    using SafeMath for uint256;
    using WadRayMath for uint256;
    using PercentageMath for uint256;    
    using SafeERC20 for IERC20;

    //main configuration parameters
    uint256 public constant MAX_STABLE_RATE_BORROW_SIZE_PERCENT = 2500;
    uint256 public constant FLASHLOAN_PREMIUM_TOTAL = 9;
    uint256 public constant MAX_NUMBER_RESERVES = 128;

    uint256 public constant UINT_MAX_VALUE = uint256(-1);

    GlobalAddressesProvider public addressesProvider;
    ILendingPoolCore public core;
    ILendingPoolDataProvider public dataProvider;
    ILendingPoolParametersProvider public parametersProvider;
    IFeeProvider public feeProvider;


// ########################
// ######  MODIFIERS ######
// ########################

    modifier onlyLendingPoolConfigurator() {
        require( msg.sender == addressesProvider.getLendingPoolConfigurator(), "Only Lending Pool Configurator can call this function" );
        _;
    }    

    modifier whenNotPaused() {
        require(!_paused, "Lending Pool is currently paused");
        _;
    }    

// ############################################################################################################
// ######  initialize() function called by proxy contract when LendingPool is added to AddressesProvider ######
// ############################################################################################################

    uint256 public constant LENDINGPOOL_REVISION = 0x1;             // NEEDED AS PART OF UPGRADABLE CONTRACTS FUNCTIONALITY ( VersionedInitializable )

    function getRevision() internal pure returns (uint256) {        // NEEDED AS PART OF UPGRADABLE CONTRACTS FUNCTIONALITY ( VersionedInitializable )
        return LENDINGPOOL_REVISION;
    }

    /**
    * @dev this function is invoked by the proxy contract when the LendingPool contract is added to the AddressesProvider.
    * @param _addressesProvider the address of the GlobalAddressesProvider registry
    **/
    function initialize(GlobalAddressesProvider _addressesProvider) public initializer {
        addressesProvider = _addressesProvider;
    }
    
    function refreshConfig() external onlyLendingPoolConfigurator {     
        refreshConfigInternal();
    }

    function refreshConfigInternal() internal {
        feeProvider = IFeeProvider(addressesProvider.getFeeProvider());
    }

// ###########################################
// ######  DEPOSIT and REDEEM FUNCTIONS ######
// ###########################################

    /**
    * @dev deposits The underlying asset into the instrument. A corresponding amount of the overlying asset (ITokens) is minted.
    * @param _instrument the address of the underlying instrument (to be deposited)
    * @param _amount the amount to be deposited
    * @param _boosterId boosterId is provided by the caller if he owns a SIGH Booster NFT to get discount on the Deposit Fee
    **/
    function deposit( address _instrument, uint256 _amount, address onBehalfOf, uint256 boosterId ) external whenNotPaused  {

        DataTypes.InstrumentData storage instrument =_instruments[_instrument];
        ValidationLogic.validateDeposit(instrument, _amount);                       // Makes the deposit checks

        address iToken = instrument.iTokenAddress;

        // Split Deposit fee in Reserve Fee and Platform Fee. Calculations based on the discount (if any) provided by the boosterId 
        (uint256 totalFee, uint256 platformFee, uint256 reserveFee) = feeProvider.calculateDepositFee(msg.sender,_instrument, _amount, boosterId);
        if (platformFee > 0) {
            IERC20(_instrument).safeTransferFrom( msg.sender, addressesProvider.getSIGHFinanceFeeCollector(), platformFee );
        }
        if (reserveFee > 0) {
            IERC20(_instrument).safeTransferFrom( msg.sender, addressesProvider.getSIGHPayAggregator(), reserveFee );
        }

        instrument.updateState();
        instrument.updateInterestRates(_instrument, iToken, _amount.sub(totalFee), 0);
        sighVolatiltiyHarvester.updateSIGHSupplyIndex(_instrument);                    // Update SIGH Liquidity Index for Instrument

        IERC20(_instrument).safeTransferFrom(msg.sender, iToken, _amount.sub(totalFee));
        bool isFirstDeposit = IAToken(iToken).mint(onBehalfOf, _amount.sub(totalFee) , instrument.liquidityIndex);

        if (isFirstDeposit) {
            _usersConfig[onBehalfOf].setUsingAsCollateral(instrument.id, true);
            emit InstrumentUsedAsCollateralEnabled(_instrument, onBehalfOf);
        }

        emit Deposit(_instrument, msg.sender, onBehalfOf,  _amount.sub(totalFee), platformFee, reserveFee, boosterId );
    }






    /**
    * @dev Withdraws the underlying amount of assets requested by _user.
    * This function is executed by the overlying IToken contract in response to a redeem action.
    * @param _instrument the address of the instrument (underlying instrument address)
    * @param _amount the underlying amount to be redeemed
   * @param to Address that will receive the underlying, same as msg.sender if the user
   *   wants to receive it on his own wallet, or a different address if the beneficiary is a  different wallet
    **/
    function withdraw( address _instrument, uint256 amount, address to) external override whenNotPaused returns(uint256) {

        DataTypes.InstrumentData storage instrument =_instruments[_instrument];
        address iToken = instrument.iTokenAddress;

        uint256 userBalance = IAToken(iToken).balanceOf(msg.sender);
        uint256 amountToWithdraw = amount;

        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        ValidationLogic.validateWithdraw( _instrument, amountToWithdraw, userBalance,_instruments, _usersConfig[msg.sender],_instrumentsList,_instrumentsCount, _addressesProvider.getPriceOracle() );

        instrument.updateState();
        instrument.updateInterestRates(_instrument, iToken, 0, amountToWithdraw);
        sighVolatiltiyHarvester.updateSIGHSupplyIndex(_instrument);                    // Update SIGH Liquidity Index for Instrument

        if (amountToWithdraw == userBalance) {
            _usersConfig[msg.sender].setUsingAsCollateral(instrument.id, false);
            emit InstrumentUsedAsCollateralDisabled(_instrument, msg.sender);
        }

        IAToken(iToken).burn(msg.sender, to, amountToWithdraw, instrument.liquidityIndex);

        emit Withdraw(_instrument, msg.sender, to, amountToWithdraw);

        return amountToWithdraw;
    }

// #########################################
// ######  BORROW and REPAY FUNCTIONS ######
// #########################################

  /**
   * @dev Allows users to borrow a specific `amount` of the reserve underlying asset, provided that the borrower
   * already deposited enough collateral, or he was given enough allowance by a credit delegator on the
   * corresponding debt token (StableDebtToken or VariableDebtToken)
   * - E.g. User borrows 100 USDC passing as `onBehalfOf` his own address, receiving the 100 USDC in his wallet
   *   and 100 stable/variable debt tokens, depending on the `interestRateMode`
   * @param asset The address of the underlying asset to borrow
   * @param amount The amount to be borrowed
   * @param interestRateMode The interest rate mode at which the user wants to borrow: 1 for Stable, 2 for Variable
   * @param boosterId BoosterId of the Booster owned by the caller
   * @param onBehalfOf Address of the user who will receive the debt. Should be the address of the borrower itself
   * calling the function if he wants to borrow against his own collateral, or the address of the credit delegator if he has been given credit delegation allowance
   **/
  function borrow( address asset, uint256 amount, uint256 interestRateMode, uint16 boosterId, address onBehalfOf ) external override whenNotPaused {
        DataTypes.InstrumentData storage instrument =_instruments[asset];

        _executeBorrow( ExecuteBorrowParams( asset, msg.sender, onBehalfOf, amount, interestRateMode, instrument.iTokenAddress, boosterId, true) );
  }


  /**
   * @notice Repays a borrowed `amount` on a specific instrument reserve, burning the equivalent debt tokens owned
   * - E.g. User repays 100 USDC, burning 100 variable/stable debt tokens of the `onBehalfOf` address
   * @param asset The address of the borrowed underlying asset previously borrowed
   * @param amount The amount to repay
   * - Send the value type(uint256).max in order to repay the whole debt for `asset` on the specific `debtMode`
   * @param rateMode The interest rate mode at of the debt the user wants to repay: 1 for Stable, 2 for Variable
   * @param onBehalfOf Address of the user who will get his debt reduced/removed. Should be the address of the
   * user calling the function if he wants to reduce/remove his own debt, or the address of any other other borrower whose debt should be removed
   * @return The final amount repaid
   **/
    function repay( address asset, uint256 amount, uint256 rateMode, address onBehalfOf ) external override whenNotPaused returns (uint256) {
        DataTypes.InstrumentData storage instrument =_instruments[asset];

        uint platformFeePay;
        uint reserveFeePay;

        (uint256 stableDebt, uint256 variableDebt) = Helpers.getUserCurrentDebt(onBehalfOf, instrument);
        DataTypes.InterestRateMode interestRateMode = DataTypes.InterestRateMode(rateMode);

        ValidationLogic.validateRepay(  instrument, amount, interestRateMode, onBehalfOf, stableDebt, variableDebt);
        uint256 paybackAmount = interestRateMode == DataTypes.InterestRateMode.STABLE ? stableDebt : variableDebt;

        // getting platfrom Fee based on if it is a Stable rate loan or variable rate loan
        uint256 platformFee = interestRateMode == DataTypes.InterestRateMode.STABLE ? 
                                                IStableDebtToken(instrument.stableDebtTokenAddress).getPlatformFee(onBehalfOf) : 
                                                IVariableDebtToken(instrument.variableDebtTokenAddress).getPlatformFee(onBehalfOf);

        // getting reserve Fee based on if it is a Stable rate loan or variable rate loan
        uint256 reserveFee = interestRateMode == DataTypes.InterestRateMode.STABLE ? 
                                                IStableDebtToken(instrument.stableDebtTokenAddress).getReserveFee(onBehalfOf) : 
                                                IVariableDebtToken(instrument.variableDebtTokenAddress).getReserveFee(onBehalfOf);

        paybackAmount = paybackAmount.add(platformFee).add(reserveFee);    // Max payback that needs to be made 

        if (amount < paybackAmount) {
            paybackAmount = amount;
        }

        // PAY PLATFORM FEE
        if ( platformFee > 0) {
            platformFeePay =  paybackAmount >= platformFee ? platformFee : paybackAmount;
            IERC20(asset).safeTransferFrom( msg.sender, addressesProvider.getSIGHFinanceFeeCollector(), platformFeePay );   // Platform Fee transferred
            paybackAmount = paybackAmount.sub(platformFeePay);  // Update payback amount
        }

        // PAY RESERVE FEE
        if (reserveFee > 0 && paybackAmount > 0) { 
            reserveFeePay =  paybackAmount > reserveFee ? reserveFee : paybackAmount;
            IERC20(asset).safeTransferFrom( msg.sender, addressesProvider.getSIGHPayAggregator(), reserveFeePay );       // Reserve Fee transferred
            paybackAmount = paybackAmount.sub(reserveFeePay);  // Update payback amount
        }    

        instrument.updateState();
        
        if (paybackAmount > 0) {
            if (interestRateMode == DataTypes.InterestRateMode.STABLE) {
                if ( platformFeePay > 0) {          // Update PLATFORM FEE
                    IStableDebtToken(instrument.stableDebtTokenAddress).updatePlatformFee(onBehalfOf, 0 ,platformFeePay);
                }
                if (reserveFee > 0) {                // Update RESERVE FEE
                    IStableDebtToken(instrument.stableDebtTokenAddress).updateReserveFee(onBehalfOf, 0 ,reserveFeePay);               
                }    
                IStableDebtToken(instrument.stableDebtTokenAddress).burn(onBehalfOf, paybackAmount);
            } 
            else {
                if ( platformFeePay > 0) {          // Update PLATFORM FEE
                    IVariableDebtToken(instrument.variableDebtTokenAddress).updatePlatformFee(onBehalfOf, 0 ,platformFeePay);
                }
                if (reserveFee > 0) {                // Update RESERVE FEE
                    IVariableDebtToken(instrument.variableDebtTokenAddress).updateReserveFee(onBehalfOf, 0 ,reserveFeePay);               
                }    
                IVariableDebtToken(instrument.variableDebtTokenAddress).burn( onBehalfOf, paybackAmount, instrument.variableBorrowIndex );
            }
        }
        else {
            emit Repay(asset, onBehalfOf, msg.sender, platformFeePay, reserveFeePay, paybackAmount);
            return platformFeePay.add(reserveFeePay);
        }


        address iToken = instrument.iTokenAddress;
        instrument.updateInterestRates(asset, iToken, paybackAmount, 0);
        sighVolatiltiyHarvester.updateSIGHBorrowIndex(asset);                    // Update SIGH Borrow Index for Instrument

        if (stableDebt.add(variableDebt).sub(paybackAmount) == 0) {
        _usersConfig[onBehalfOf].setBorrowing(instrument.id, false);
        }

        IERC20(asset).safeTransferFrom(msg.sender, iToken, paybackAmount);

        emit Repay(asset, onBehalfOf, msg.sender, platformFeePay, reserveFeePay, paybackAmount);

        return paybackAmount;
  }

// ####################################################################
// ######  1. SWAP BETWEEN STABLE AND VARIABLE BORROW RATE MODES ######
// ######  2. REBALANCES THE STABLE INTEREST RATE OF A USER      ######
// ####################################################################

  /**
   * @dev Allows a borrower to swap his debt between stable and variable mode, or viceversa
   * @param asset The address of the underlying asset borrowed
   * @param rateMode The rate mode that the user wants to swap to
   **/
  function swapBorrowRateMode(address asset, uint256 rateMode) external override whenNotPaused {
    DataTypes.InstrumentData storage instrument =_instruments[asset];

    (uint256 stableDebt, uint256 variableDebt) = Helpers.getUserCurrentDebt(msg.sender, instrument);
    DataTypes.InterestRateMode interestRateMode = DataTypes.InterestRateMode(rateMode);

    ValidationLogic.validateSwapRateMode( instrument, _usersConfig[msg.sender], stableDebt, variableDebt, interestRateMode);

    instrument.updateState();

    if (interestRateMode == DataTypes.InterestRateMode.STABLE) {
      IStableDebtToken(instrument.stableDebtTokenAddress).burn(msg.sender, stableDebt);
      IVariableDebtToken(instrument.variableDebtTokenAddress).mint( msg.sender, msg.sender, stableDebt, instrument.variableBorrowIndex );
    } 
    else {
      IVariableDebtToken(instrument.variableDebtTokenAddress).burn( msg.sender, variableDebt, instrument.variableBorrowIndex);
      IStableDebtToken(instrument.stableDebtTokenAddress).mint( msg.sender, msg.sender, variableDebt, instrument.currentStableBorrowRate);
    }

    instrument.updateInterestRates(asset, instrument.iTokenAddress, 0, 0);
    sighVolatiltiyHarvester.updateSIGHBorrowIndex(asset);                    // Update SIGH Borrow Index for Instrument

    emit Swap(asset, msg.sender, rateMode);
  }

  /**
   * @dev Rebalances the stable interest rate of a user to the current stable rate defined on the instrument reserve.
   * - Users can be rebalanced if the following conditions are satisfied:
   *     1. Usage ratio is above 95%
   *     2. the current deposit APY is below REBALANCE_UP_THRESHOLD * maxVariableBorrowRate, which means that too much has been
   *        borrowed at a stable rate and depositors are not earning enough
   * @param asset The address of the underlying asset borrowed
   * @param user The address of the user to be rebalanced
   **/
  function rebalanceStableBorrowRate(address asset, address user) external override whenNotPaused {
    DataTypes.InstrumentData storage instrument =_instruments[asset];

    IERC20 stableDebtToken = IERC20(instrument.stableDebtTokenAddress);
    IERC20 variableDebtToken = IERC20(instrument.variableDebtTokenAddress);
    address iTokenAddress = instrument.iTokenAddress;

    uint256 stableDebt = IERC20(stableDebtToken).balanceOf(user);

    ValidationLogic.validateRebalanceStableBorrowRate(instrument,asset,stableDebtToken,variableDebtToken,iTokenAddress);
    instrument.updateState();

    IStableDebtToken(address(stableDebtToken)).burn(user, stableDebt);
    IStableDebtToken(address(stableDebtToken)).mint(user,user,stableDebt, instrument.currentStableBorrowRate);

    instrument.updateInterestRates(asset, iTokenAddress, 0, 0);
    sighVolatiltiyHarvester.updateSIGHBorrowIndex(asset);                    // Update SIGH Borrow Index for Instrument

    emit RebalanceStableBorrowRate(asset, user);
  }

// #####################################################################################################
// ######  1. DEPOSITORS CAN ENABLE DISABLE SPECIFIC DEPOSIT AS COLLATERAL                  ############
// ######  2. FUNCTION WHICH CAN BE INVOKED TO LIQUIDATE AN UNDERCOLLATERALIZED POSITION    ############
// #####################################################################################################

    /**
    * @dev allows depositors to enable or disable a specific deposit as collateral.
    * @param _instrument the address of the instrument
    * @param _useAsCollateral true if the user wants to user the deposit as collateral, false otherwise.
    **/
    function setUserUseInstrumentAsCollateral(address _instrument, bool _useAsCollateral) external override whenNotPaused {
        DataTypes.InstrumentData storage instrument =_instruments[asset];

        ValidationLogic.validateSetUseReserveAsCollateral(instrument, asset, useAsCollateral , _reserves, _usersConfig[msg.sender],_reservesList, _instrumentsCount, _addressesProvider.getPriceOracle() );
        _usersConfig[msg.sender].setUsingAsCollateral(instrument.id, useAsCollateral);

        if (useAsCollateral) {
            emit InstrumentUsedAsCollateralEnabled(asset, msg.sender);
        } 
        else {
            emit InstrumentUsedAsCollateralDisabled(asset, msg.sender);
        }
    }

  /**
   * @dev Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
   * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
   *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
   * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of the liquidation
   * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
   * @param user The address of the borrower getting liquidated
   * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
   * @param receiveAToken `true` if the liquidators wants to receive the collateral iTokens, `false` if he wants to receive the underlying collateral asset directly
   **/
    function liquidationCall( address collateralAsset, address debtAsset, address user, uint256 debtToCover, bool _receiveIToken ) external override whenNotPaused {
        address collateralManager = _addressesProvider.getLendingPoolCollateralManager();

        (bool success, bytes memory result) =  collateralManager.delegatecall( abi.encodeWithSignature('liquidationCall(address,address,address,uint256,bool)', collateralAsset, debtAsset, user, debtToCover, _receiveIToken ) );
        require(success, Errors.LP_LIQUIDATION_CALL_FAILED);

        (uint256 returnCode, string memory returnMessage) = abi.decode(result, (uint256, string));

        require(returnCode == 0, string(abi.encodePacked(returnMessage)));
  }

// ################################################################################################################
// ######  1. FLASH LOAN (total fee = protocol fee + fee distributed among depositors)                 ############
// ################################################################################################################

  /**
   * @dev Allows smartcontracts to access the liquidity of the pool within one transaction, as long as the amount taken plus a fee is returned.
   * IMPORTANT There are security concerns for developers of flashloan receiver contracts that must be kept into consideration.
   * For further details please visit https://developers.aave.com
   * @param receiverAddress The address of the contract receiving the funds, implementing the IFlashLoanReceiver interface
   * @param assets The addresses of the assets being flash-borrowed
   * @param amounts The amounts amounts being flash-borrowed
   * @param modes Types of the debt to open if the flash loan is not returned:
   *   0 -> Don't open any debt, just revert if funds can't be transferred from the receiver
   *   1 -> Open debt at stable rate for the value of the amount flash-borrowed to the `onBehalfOf` address
   *   2 -> Open debt at variable rate for the value of the amount flash-borrowed to the `onBehalfOf` address
   * @param onBehalfOf The address  that will receive the debt in the case of using on `modes` 1 or 2
   * @param params Variadic packed params to pass to the receiver as extra information
   * @param boosterId Code used to register the integrator originating the operation, for potential rewards.
   *   0 if the action is executed directly by the user, without any middle-man
   **/
  function flashLoan( address receiverAddress, address[] calldata assets, uint256[] calldata amounts, uint256[] calldata modes, address onBehalfOf, bytes calldata params, uint16 boosterId) external override whenNotPaused {
    FlashLoanLocalVars memory vars;

    ValidationLogic.validateFlashloan(assets, amounts);

    address[] memory iTokenAddresses = new address[](assets.length);
    uint256[] memory premiums = new uint256[](assets.length);

    vars.receiver = IFlashLoanReceiver(receiverAddress);

    for (vars.i = 0; vars.i < assets.length; vars.i++) {
        iTokenAddresses[vars.i] =_instruments[assets[vars.i]].iTokenAddress;
        premiums[vars.i] = feeProvider.calculateFlashLoanFee(msg.sender, amounts[vars.i], boosterId);
        IAToken(iTokenAddresses[vars.i]).transferUnderlyingTo(receiverAddress, amounts[vars.i]);
    }

    require( vars.receiver.executeOperation(assets, amounts, premiums, msg.sender, params), "ExecuteOperation() invalid return");

    for (vars.i = 0; vars.i < assets.length; vars.i++) {
        vars.currentAsset = assets[vars.i];
        vars.currentAmount = amounts[vars.i];
        vars.currentPremium = premiums[vars.i];
        vars.currentiTokenAddress = iTokenAddresses[vars.i];
        vars.currentAmountPlusPremium = vars.currentAmount.add(vars.currentPremium);

      if (DataTypes.InterestRateMode(modes[vars.i]) == DataTypes.InterestRateMode.NONE) {
       _instruments[vars.currentAsset].updateState();
       _instruments[vars.currentAsset].cumulateToLiquidityIndex( IERC20(vars.currentiTokenAddress).totalSupply(), vars.currentPremium );
       _instruments[vars.currentAsset].updateInterestRates(  vars.currentAsset, vars.currentiTokenAddress, vars.currentAmountPlusPremium, 0 );
        sighVolatiltiyHarvester.updateSIGHBorrowIndex(vars.currentAsset);                    // Update SIGH Borrow Index for Instrument

        IERC20(vars.currentAsset).safeTransferFrom( receiverAddress, vars.currentiTokenAddress, vars.currentAmountPlusPremium);
      } 
      else {
        // If the user chose to not return the funds, the system checks if there is enough collateral and eventually opens a debt position
        _executeBorrow( ExecuteBorrowParams( vars.currentAsset, msg.sender, onBehalfOf, vars.currentAmount, modes[vars.i], vars.currentiTokenAddress, boosterId, false ) );
      }
      emit FlashLoan(  receiverAddress, msg.sender, vars.currentAsset, vars.currentAmount, vars.currentPremium, boosterId );
    }
  }



// ####################################################################
// ######  VIEW FUNCTIONS TO FETCH DATA FROM THE CORE CONTRACT  ############
// ######  1. getInstrumentConfigurationData()  ############
// ######  2. getInstrumentData()  ############
// ######  3. getUserAccountData()  ############
// ######  4. getUserInstrumentData()  ############
// ######  5. getUserInstrumentData()  ############
// ####################################################################


    // Returns the state and configuration of the instrument reserve
    function getInstrumentData(address _instrument) external view returns (DataTypes.InstrumentData memory) {
        return _instruments[asset];
    }

    // Returns the user account data across all the instrument reserves
    function getUserAccountData(address _user) external view returns ( uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 availableBorrowsUSD, uint256 currentLiquidationThreshold, uint256 ltv, uint256 healthFactor ) {
        ( totalCollateralUSD, totalDebtUSD, ltv, currentLiquidationThreshold, healthFactor ) = GenericLogic.calculateUserAccountData( user,_instruments, _usersConfig[user],_instrumentsList,_instrumentsCount, _addressesProvider.getPriceOracle() );
        availableBorrowsUSD = GenericLogic.calculateAvailableBorrowsUSD( totalCollateralUSD, totalDebtUSD, ltv );
    }

    function getInstrumentConfigurationData(address _instrument) external view returns ( DataTypes.InstrumentConfigurationMap memory ) {
        return_instruments[asset].configuration;
    }

    // Returns the configuration of the user across all the instrument reserves
    function getUserConfiguration(address user) external view override returns (DataTypes.UserConfigurationMap memory) {
        return _usersConfig[user];
    }

   // Returns the normalized income per unit of asset
    function getReserveNormalizedIncome(address asset) external view virtual override returns (uint256) {
        return_instruments[asset].getNormalizedIncome();
    }

  
   // Returns the normalized variable debt per unit of asset
    function getReserveNormalizedVariableDebt(address asset) external view override returns (uint256) {
        return_instruments[asset].getNormalizedDebt();
    }

   // Returns if the LendingPool is paused
    function paused() external view override returns (bool) {
        return _paused;
    }

    // Returns the list of the initialized reserves
    function getInstrumentsList() external view override returns (address[] memory) {
        address[] memory _activeInstruments = new address[](_instrumentsCount);

        for (uint256 i = 0; i <_instrumentsCount; i++) {
            _activeInstruments[i] =_instrumentsList[i];
        }
        return _activeInstruments;
    }

    // Returns the cached LendingPoolAddressesProvider connected to this contract
    function getAddressesProvider() external view override returns (IGlobalAddressesProvider) {
        return _addressesProvider;
    }

// ####################################################################
// ######  FUNCTIONS TO VALIDATE THE TRANSFER  ############
// ######  1. finalizeTransfer()  ############
// ####################################################################

    /**
    * @dev Validates and finalizes an iToken transfer. Only callable by the overlying iToken of the `asset`
    * @param asset The address of the underlying asset of the iToken
    * @param from The user from which the iTokens are transferred
    * @param to The user receiving the iTokens
    * @param amount The amount being transferred/withdrawn
    * @param balanceFromBefore The iToken balance of the `from` user before the transfer
    * @param balanceToBefore The iToken balance of the `to` user before the transfer
    */
    function finalizeTransfer( address asset, address from,  address to, uint256 amount,  uint256 balanceFromBefore, uint256 balanceToBefore ) external override whenNotPaused {
        require(msg.sender ==_instruments[asset].iTokenAddress, "Only the associated IToken can call this function");

        ValidationLogic.validateTransfer( from,_instruments, _usersConfig[from],_instrumentsList,_instrumentsCount, _addressesProvider.getPriceOracle() );
        sighVolatiltiyHarvester.updateSIGHSupplyIndex(asset);                    // Update SIGH Supply Index for Instrument

        uint256 instrumentId =_instruments[asset].id;

        if (from != to) {
            if (balanceFromBefore.sub(amount) == 0) {
                DataTypes.UserConfigurationMap storage fromConfig = _usersConfig[from];
                fromConfig.setUsingAsCollateral(instrumentId, false);
                emit InstrumentUsedAsCollateralDisabled(asset, from);
            }
            if (balanceToBefore == 0 && amount != 0) {
                DataTypes.UserConfigurationMap storage toConfig = _usersConfig[to];
                toConfig.setUsingAsCollateral(instrumentId, true);
                emit InstrumentUsedAsCollateralEnabled(asset, to);
            }
        }
    }

// ####################################################################
// ######  ADMIN FUNCTIONS ############
// ######  1. initInstrument()  ############
// ######  1. setInstrumentInterestRateStrategyAddress()  ############
// ######  1. setConfiguration()  ############
// ######  1. setPause()  ############
// ####################################################################

    /**
    * @dev Initializes a reserve, activating it, assigning an iToken and debt tokens and an interest rate strategy
    * - Only callable by the LendingPoolConfigurator contract
    * @param asset The address of the underlying asset of the reserve
    * @param iTokenAddress The address of the iToken that will be assigned to the reserve
    * @param stableDebtAddress The address of the StableDebtToken that will be assigned to the reserve
    * @param iTokenAddress The address of the VariableDebtToken that will be assigned to the reserve
    * @param interestRateStrategyAddress The address of the interest rate strategy contract
    **/
    function initInstrument(  address asset,  address iTokenAddress,  address stableDebtAddress,  address variableDebtAddress, address interestRateStrategyAddress ) external override onlyLendingPoolConfigurator {
        require(Address.isContract(asset), Errors.LP_NOT_CONTRACT);
       _instruments[asset].init( iTokenAddress, stableDebtAddress, variableDebtAddress, interestRateStrategyAddress );
        _addInstrumentToList(asset);
    }

    /**
    * @dev Updates the address of the interest rate strategy contract. Only callable by the LendingPoolConfigurator contract
    * @param asset The address of the underlying asset of the reserve
    * @param rateStrategyAddress The address of the interest rate strategy contract
    **/
    function setInstrumentInterestRateStrategyAddress(address asset, address rateStrategyAddress) external override onlyLendingPoolConfigurator {
       _instruments[asset].interestRateStrategyAddress = rateStrategyAddress;
    }

    /**
    * @dev Sets the configuration bitmap of the instrument as a whole. Only callable by the LendingPoolConfigurator contract
    * @param asset The address of the underlying asset of the instrument
    * @param configuration The new configuration bitmap
    **/
    function setConfiguration(address asset, uint256 configuration) external override onlyLendingPoolConfigurator {
       _instruments[asset].configuration.data = configuration;
    }

    /**
    * @dev Set the _pause state of a instrument. Only callable by the LendingPoolConfigurator contract
    * @param val `true` to pause the instrument, `false` to un-pause it
    */
    function setPause(bool val) external override onlyLendingPoolConfigurator {
        _paused = val;
        if (_paused) {
            emit Paused();
        } 
        else {
            emit Unpaused();
        }
    }

// ####################################################################
// ######  INTERNAL FUNCTIONS ############
// ######  1. initInstrument()  ############
// ######  1. setInstrumentInterestRateStrategyAddress()  ############
// ######  1. setConfiguration()  ############
// ######  1. setPause()  ############
// ####################################################################

    struct ExecuteBorrowParams {
        address asset;
        address user;
        address onBehalfOf;
        uint256 amount;
        uint256 interestRateMode;
        address iTokenAddress;
        uint16 boosterId;
        bool releaseUnderlying;
    }

    function _executeBorrow(ExecuteBorrowParams memory vars) internal {
        DataTypes.InstrumentData storage instrument =_instruments[vars.asset];
        DataTypes.UserConfigurationMap storage userConfig = _usersConfig[vars.onBehalfOf];

        address oracle = _addressesProvider.getPriceOracle();
        uint256 amountInUSD = IPriceOracleGetter(oracle).getAssetPrice(vars.asset).mul(vars.amount).div(  10**instrument.configuration.getDecimals() );

        ValidationLogic.validateBorrow( vars.asset, instrument, vars.onBehalfOf, vars.amount, amountInUSD, vars.interestRateMode, MAX_STABLE_RATE_BORROW_SIZE_PERCENT,_instruments, userConfig,_instrumentsList,_instrumentsCount, oracle );
        instrument.updateState();

        uint256 currentStableRate = 0;
        bool isFirstBorrowing = false;
        (uint256 platformFee, uint256 reserveFee) = feeProvider.calculateBorrowFee(onBehalfOf,_instrument, vars.amount, boosterId);

        if (DataTypes.InterestRateMode(vars.interestRateMode) == DataTypes.InterestRateMode.STABLE) {
            currentStableRate = instrument.currentStableBorrowRate;
            isFirstBorrowing = IStableDebtToken(instrument.stableDebtTokenAddress).mint( vars.user, vars.onBehalfOf, vars.amount, currentStableRate );
            IStableDebtToken(instrument.stableDebtTokenAddress).updatePlatformFee(vars.user,platformFee,0);
            IStableDebtToken(instrument.stableDebtTokenAddress).updateReserveFee(vars.user,reserveFee,0);
        } 
        else {
            isFirstBorrowing = IVariableDebtToken(instrument.variableDebtTokenAddress).mint( vars.user, vars.onBehalfOf, vars.amount, instrument.variableBorrowIndex );
            IVariableDebtToken(instrument.variableDebtTokenAddress).updatePlatformFee(vars.user,platformFee,0);
            IVariableDebtToken(instrument.variableDebtTokenAddress).updateReserveFee(vars.user,reserveFee,0);
        }

        if (isFirstBorrowing) {
            userConfig.setBorrowing(instrument.id, true);
        }

        instrument.updateInterestRates( vars.asset, vars.iTokenAddress, 0, vars.releaseUnderlying ? vars.amount : 0 );

        if (vars.releaseUnderlying) {
            IAToken(vars.iTokenAddress).transferUnderlyingTo(vars.user, vars.amount);
        }

        emit Borrow( vars.asset, vars.user, vars.onBehalfOf, vars.amount, vars.interestRateMode, DataTypes.InterestRateMode(vars.interestRateMode) == DataTypes.InterestRateMode.STABLE ? currentStableRate : reserve.currentVariableBorrowRate, vars.boosterId );
    }



    function _addInstrumentToList(address asset) internal {
        uint256 instrumentsCount =_instrumentsCount;
        require(instrumentsCount < MAX_NUMBER_RESERVES, Errors.LP_NO_MORE_RESERVES_ALLOWED);
        bool instrumentAlreadyAdded =_instruments[asset].id != 0 ||_instrumentsList[0] == asset;

        if (!instrumentAlreadyAdded) {
           _instruments[asset].id = uint8(instrumentsCount);
           _instrumentsList[instrumentsCount] = asset;
           _instrumentsCount = instrumentsCount + 1;
        }
    }
}














    function getUserInstrumentData(address _instrument, address _user) external view returns (
            uint256 currentITokenBalance,
            uint256 currentBorrowBalance,
            uint256 principalBorrowBalance,
            uint256 borrowRateMode,
            uint256 borrowRate,
            uint256 liquidityRate,
            uint256 borrowFee,
            uint256 variableBorrowIndex,
            uint256 lastUpdateTimestamp,
            bool usageAsCollateralEnabled
        )
    {
        return dataProvider.getUserInstrumentData(_instrument, _user);
    }

    function getInstruments() external view returns (address[] memory) {
        return core.getInstruments();
    }

// ########################################
// ######  INTERNAL FUNCTIONS  ############
// ########################################
    /**
    * @dev internal function to save on code size for the onlyActiveInstrument modifier
    **/
    function requireInstrumentActiveInternal(address _instrument) internal view {
        require(core.getInstrumentIsActive(_instrument), "Action requires an active instrument");
    }

    /**
    * @notice internal function to save on code size for the onlyUnfreezedInstrument modifier
    **/
    function requireInstrumentNotFreezedInternal(address _instrument) internal view {
        require(!core.getInstrumentIsFreezed(_instrument), "Action requires an unfreezed instrument");
    }

    /**
    * @notice internal function to save on code size for the onlyAmountGreaterThanZero modifier
    **/
    function requireAmountGreaterThanZeroInternal(uint256 _amount) internal pure {
        require(_amount > 0, "Amount must be greater than 0");
    }
}
