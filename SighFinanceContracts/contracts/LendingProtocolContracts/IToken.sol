pragma solidity ^0.5.0;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20Detailed.sol";

import "../Configuration/IGlobalAddressesProvider.sol";
import "./interfaces/ILendingPool.sol";
import "./interfaces/ILendingPoolDataProvider.sol";
import "./interfaces/ILendingPoolCore.sol";
import "./interfaces/ISighStream.sol";     

import "./libraries/WadRayMath.sol";

/**
 * @title Aave ERC20 Itokens (modified by SIGH Finance)
 *
 * @dev Implementation of the interest bearing token for the protocol.
 * @author Aave, SIGH Finance (modified by SIGH Finance)
 */
contract IToken is ERC20, ERC20Detailed {

    using WadRayMath for uint256;

    uint256 public constant UINT_MAX_VALUE = uint256(-1);

    address public underlyingInstrumentAddress;

    IGlobalAddressesProvider private addressesProvider;     // Only used in Constructor()
    ILendingPoolCore private core;                          // Fetches borrow balances
    ILendingPool private pool;                              // calls redeem underlying
    ILendingPoolDataProvider private dataProvider;          // checks if transfer is possible
    ISighStream private sighStream;                         // SIGH STREAMING FUNCTIONALITY

    mapping (address => uint256) private userIndexes;                       // index values. Taken from core lending pool contract
    mapping (address => address) private interestRedirectionAddresses;      // Address to which the interest stream is being redirected
    mapping (address => uint256) private redirectedBalances;
    mapping (address => address) public interestRedirectionAllowances;     // Address allowed to perform interest redirection by the user
    

// ########################
// ######  EVENTS #########
// ########################

    /**
    * @dev emitted after the redeem action
    * @param _from the address performing the redeem
    * @param _value the amount to be redeemed
    * @param _fromBalanceIncrease the cumulated balance since the last update of the user
    * @param _fromIndex the last index of the user
    **/
    event Redeem(address indexed _from,uint256 _value, uint256 _fromBalanceIncrease, uint256 _fromIndex);

    /**
    * @dev emitted after the mint action
    * @param _from the address performing the mint
    * @param _value the amount to be minted
    * @param _fromBalanceIncrease the cumulated balance since the last update of the user
    * @param _fromIndex the last index of the user
    **/
    event MintOnDeposit(address indexed _from, uint256 _value, uint256 _fromBalanceIncrease, uint256 _fromIndex);

    /**
    * @dev emitted during the liquidation action, when the liquidator reclaims the underlying asset
    * @param _from the address from which the tokens are being burned
    * @param _value the amount to be burned
    * @param _fromBalanceIncrease the cumulated balance since the last update of the user
    * @param _fromIndex the last index of the user
    **/
    event BurnOnLiquidation(address indexed _from, uint256 _value, uint256 _fromBalanceIncrease, uint256 _fromIndex);

    /**
    * @dev emitted during the transfer action
    * @param _from the address from which the tokens are being transferred
    * @param _to the adress of the destination
    * @param _value the amount to be minted
    * @param _fromBalanceIncrease the cumulated balance since the last update of the user
    * @param _toBalanceIncrease the cumulated balance since the last update of the destination
    * @param _fromIndex the last index of the user
    * @param _toIndex the last index of the liquidator
    **/
    event BalanceTransfer( address indexed _from, address indexed _to, uint256 _value, uint256 _fromBalanceIncrease, uint256 _toBalanceIncrease, uint256 _fromIndex, uint256 _toIndex );


    // INTEREST STREAMS RELATED EVENTS

    event InterestStreamRedirected( address indexed _from, address indexed _to, uint256 _redirectedBalance, uint256 _fromBalanceIncrease, uint256 _fromIndex);
    event InterestRedirectionAllowanceChanged( address indexed _from, address indexed _to );
    event InterestRedirectedBalanceUpdated( address interestRedirectionAddress, uint balanceToAdd, uint balanceToRemove, uint totalRedirectedBalanceForInterest );


// ###########################
// ######  MODIFIERS #########
// ###########################

    modifier onlyLendingPool {
        require( msg.sender == address(pool), "The caller of this function must be the lending pool");
        _;
    }

    modifier onlyLendingPoolCore {
        require( msg.sender == address(core), "The caller of this function must be the lending pool Core");
        _;
    }

    modifier whenTransferAllowed(address _from, uint256 _amount) {
        require(isTransferAllowed(_from, _amount), "Transfer cannot be allowed.");
        _;
    }

    modifier onlySighStream {
        require( msg.sender == address(sighStream), "The caller of this function must be the $SIGH Stream Contract");
        _;
    }

    /**   
     * @dev Used to validate transfers before actually executing them.
     * @param _user address of the user to check
     * @param _amount the amount to check
     * @return true if the _user can transfer _amount, false otherwise
     **/
    function isTransferAllowed(address _user, uint256 _amount) public view returns (bool) {
        return dataProvider.balanceDecreaseAllowed(underlyingInstrumentAddress, _user, _amount);
    }

// ################################################################################################################################################
// ######  CONSTRUCTOR ############################################################################################################################
// ######  1. Sets the underlyingInstrumentAddress, name, symbol, decimals.              ###############################################################
// ######  2. The GlobalAddressesProvider's address is used to get the LendingPoolCore #######################################################
// ######     contract address, LendingPool contract address, and the LendingPoolDataProvider contract address and set them.    ###################
// ################################################################################################################################################

   constructor( address _addressesProvider,  address _underlyingAsset, uint8 _underlyingAssetDecimals, string memory _name, string memory _symbol) public ERC20Detailed(_name, _symbol, _underlyingAssetDecimals) {
        addressesProvider = IGlobalAddressesProvider(_addressesProvider);
        core = ILendingPoolCore(addressesProvider.getLendingPoolCore());
        pool = ILendingPool(addressesProvider.getLendingPool());
        dataProvider = ILendingPoolDataProvider(addressesProvider.getLendingPoolDataProvider());
        underlyingInstrumentAddress = _underlyingAsset;
    }

   function setSighStreamAddress( address _sighStreamAddress )  external returns (bool) {
       require(msg.sender == address(core),"Only Lending Pool Core can call this function");
        sighStream = ISighStream(_sighStreamAddress);
        return true;
   }

// ###############################################################################################
// ######  MINT NEW ITOKENS ON DEPOST ############################################################
// ######  1. Can only be called by lendingPool Contract (called after amount is transferred) $$$$
// ######  2. If interest is being redirected, it adds the amount which is #######################
// ######     deposited to the increase in balance (through interest) and ########################
// ######     updates the redirected balance. ####################################################
// ######  3. It then mints new ITokens  #########################################################
// ###############################################################################################

    /**
     * @dev mints token in the event of users depositing the underlying asset into the lending pool. Only lending pools can call this function
     * @param _account the address receiving the minted tokens
     * @param _amount the amount of tokens to mint
     */
    function mintOnDeposit(address _account, uint256 _amount) external onlyLendingPool {
        (, uint256 currentCompoundedBalance, uint256 balanceIncrease, uint256 index) = cumulateBalanceInternal(_account);       //calculates new interest generated and mints the ITokens (based on interest)
        sighStream.accureLiquiditySighStream(_account,balanceIncrease,currentCompoundedBalance);                                                          // ADDED BY SIGH FINANCE (ACCURS SIGH FOR DEPOSITOR)

         //if the user is redirecting his interest / Liquidity $SIGH Stream towards someone else, we update the redirected balance 
         // of the redirection addresses by adding 1. Accrued interest, 2. Amount Deposited
        updateRedirectedBalanceOfRedirectionAddressesInternal(_account, balanceIncrease.add(_amount), 0);
        sighStream.updateRedirectedBalanceOfLiquiditySIGHStreamRedirectionAddress(_account,balanceIncrease.add(_amount),0);
        _mint(_account, _amount);       //mint an equivalent amount of tokens to cover the new deposit

        emit MintOnDeposit(_account, _amount, balanceIncrease, index);
    }

// ###########################################################################################################################
// ######  REDEEM UNDERLYING TOKENS ##########################################################################################
// ######  1. If interest is being redirected, it adds the increase in balance (through interest) and ########################
// ######     subtracts the amount to be redeemed to the redirected balance. #################################################
// ######  2. It then burns the ITokens equal to amount to be redeemed  ###################################################### 
// ######  3. It then calls redeemUnderlying function of lendingPool Contract to transfer the underlying amount  #############
// #########################################################

    /**
    * @dev redeems Itoken for the underlying asset
    * @param _amount the amount being redeemed
    **/
    function redeem(uint256 _amount) external {

        require(_amount > 0, "Amount to redeem needs to be > 0");
        
        (, uint256 currentBalance, uint256 balanceIncrease, uint256 index) = cumulateBalanceInternal(msg.sender);   //cumulates the balance of the user
        uint256 amountToRedeem = _amount;

        //if amount is equal to uint(-1), the user wants to redeem everything
        if(_amount == UINT_MAX_VALUE){
            amountToRedeem = currentBalance;
        }

        require(amountToRedeem <= currentBalance, "User cannot redeem more than the available balance");
        require(isTransferAllowed(msg.sender, amountToRedeem), "Transfer cannot be allowed.");       //check that the user is allowed to redeem the amount

        pool.redeemUnderlying( underlyingInstrumentAddress, msg.sender, amountToRedeem, currentBalance.sub(amountToRedeem) );   // executes redeem of the underlying asset
        sighStream.accureLiquiditySighStream(msg.sender,balanceIncrease,currentBalance );                                                          // ADDED BY SIGH FINANCE (ACCURS SIGH FOR REDEEMER)

        //if the user is redirecting his interest towards someone else,
        //we update the redirected balance of the redirection address by adding the accrued interest, and removing the amount to redeem
        updateRedirectedBalanceOfRedirectionAddressesInternal(msg.sender, balanceIncrease, amountToRedeem);
        sighStream.updateRedirectedBalanceOfLiquiditySIGHStreamRedirectionAddress(msg.sender, balanceIncrease, amountToRedeem);

        _burn(msg.sender, amountToRedeem);      // burns tokens equivalent to the amount requested

        bool userIndexReset = false;
        
        if(currentBalance.sub(amountToRedeem) == 0){        //reset the user data if the remaining balance is 0
            userIndexReset = resetDataOnZeroBalanceInternal(msg.sender);
        }

        emit Redeem(msg.sender, amountToRedeem, balanceIncrease, userIndexReset ? 0 : index);
    }

// #########################################################################################################
// ######  BURN ITOKENS WHEN LIQUIDATION OCCURS ############################################################
// ######  1. Can only be called by lendingPool Contract  ##################################################
// ######  1. If interest is being redirected, it adds the increase in balance (through interest) and  #####
// ######     subtracts the amount to be burnt to the redirected balance. ##################################
// ######  2. It then burns the ITokens equal to amount to be burnt   ######################################
// #########################################################################################################

    /**
     * @dev burns token in the event of a borrow being liquidated, in case the liquidators reclaims the underlying asset
     * Transfer of the liquidated asset is executed by the lending pool contract.
     * only lending pools can call this function
     * @param _account the address from which burn the Itokens
     * @param _value the amount to burn
     **/
    function burnOnLiquidation(address _account, uint256 _value) external onlyLendingPool {
        (,uint256 accountBalance,uint256 balanceIncrease,uint256 index) = cumulateBalanceInternal(_account);    //cumulates the balance of the user being liquidated
        sighStream.accureLiquiditySighStream(_account,balanceIncrease,accountBalance);                                                          // ADDED BY SIGH FINANCE (ACCURS SIGH FOR REDEEMER)

        //adds the accrued interest and substracts the burned amount to the redirected balance
        updateRedirectedBalanceOfRedirectionAddressesInternal(_account, balanceIncrease, _value);
        sighStream.updateRedirectedBalanceOfLiquiditySIGHStreamRedirectionAddress(_account, balanceIncrease, _value);
        _burn(_account, _value);        //burns the requested amount of tokens

        bool userIndexReset = false;
        if(accountBalance.sub(_value) == 0){        //reset the user data if the remaining balance is 0
            userIndexReset = resetDataOnZeroBalanceInternal(_account);
        }

        emit BurnOnLiquidation(_account, _value, balanceIncrease, userIndexReset ? 0 : index);
    }

// ##################################################################################################################################################################
// ######  TRANSFER FUNCTIONALITY ###################################################################################################################################
// ######  1. transferOnLiquidation() : Can only be called by lendingPool Contract. Called to transfer Collateral when liquidating  #################################
// ######  2. _transfer() : Over-rides the internal _transfer() called by the ERC20's transfer() & transferFrom() ###################################################
// ######  3. executeTransferInternal() --> It actually executes the transfer. Accures interest and updates redirected balances before executing transfer.  #########
// ##################################################################################################################################################################

    /**
     * @dev transfers tokens in the event of a borrow being liquidated, in case the liquidators reclaims the Itoken  only lending pools can call this function
     * @param _from the address from which transfer the Itokens
     * @param _to the destination address
     * @param _value the amount to transfer
     **/
    function transferOnLiquidation(address _from, address _to, uint256 _value) external onlyLendingPool {
        executeTransferInternal(_from, _to, _value);
    }

    /**
     * @notice ERC20 implementation internal function backing transfer() and transferFrom()
     * @dev validates the transfer before allowing it. NOTE: This is not standard ERC20 behavior
     **/
    function _transfer(address _from, address _to, uint256 _amount) internal whenTransferAllowed(_from, _amount) {
        executeTransferInternal(_from, _to, _amount);
    }

    /**
    * @dev executes the transfer of Itokens, invoked by both _transfer() and transferOnLiquidation()
    * @param _from the address from which transfer the Itokens
    * @param _to the destination address
    * @param _value the amount to transfer
    **/
    function executeTransferInternal( address _from, address _to,  uint256 _value) internal {
        require(_value > 0, "Transferred amount needs to be greater than zero");
        (, uint256 fromBalance, uint256 fromBalanceIncrease, uint256 fromIndex ) = cumulateBalanceInternal(_from);   //cumulate the balance of the sender
        (, uint256 toBalance, uint256 toBalanceIncrease, uint256 toIndex ) = cumulateBalanceInternal(_to);       //cumulate the balance of the receiver

        sighStream.accureLiquiditySighStream(_from, fromBalanceIncrease, fromBalance);                                                          // ADDED BY SIGH FINANCE (ACCURS SIGH FOR From Account)
        sighStream.accureLiquiditySighStream(_to, toBalanceIncrease, toBalance);                                                            // ADDED BY SIGH FINANCE (ACCURS SIGH FOR To Account)
        
        //if the sender is redirecting his interest towards someone else, adds to the redirected balance the accrued interest and removes the amount being transferred
        updateRedirectedBalanceOfRedirectionAddressesInternal(_from, fromBalanceIncrease, _value);
        sighStream.updateRedirectedBalanceOfLiquiditySIGHStreamRedirectionAddress(_from, fromBalanceIncrease, _value);

        //if the receiver is redirecting his $SIGH Liquidity Stream towards someone else, adds to the redirected balance the accrued interest and the amount being transferred
        updateRedirectedBalanceOfRedirectionAddressesInternal(_to, toBalanceIncrease.add(_value), 0);
        sighStream.updateRedirectedBalanceOfLiquiditySIGHStreamRedirectionAddress(_to, toBalanceIncrease.add(_value), 0);

        super._transfer(_from, _to, _value);        //performs the transfer

        bool fromIndexReset = false;
        
        if(fromBalance.sub(_value) == 0){           //reset the user data if the remaining balance is 0
            fromIndexReset = resetDataOnZeroBalanceInternal(_from);
        }

        emit BalanceTransfer(  _from, _to, _value, fromBalanceIncrease, toBalanceIncrease, fromIndexReset ? 0 : fromIndex, toIndex);
    }



// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ######  REDIRECTING INTEREST STREAMS: FUNCTIONALITY #######################################################################################################
// ######  1. redirectInterestStream() : User himself redirects his interest stream.  ########################################################################
// ######  2. allowInterestRedirectionTo() : User gives the permission of redirecting the interest stream to another account  ################################ 
// ######  2. redirectInterestStreamOf() : When account given the permission to redirect interest stream (by the user) redirects the stream.  ################
// ######  3. redirectInterestStreamInternal() --> Executes the redirecting of the interest stream  ##########################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################

    /**
    * @dev redirects the interest generated to a target address. When the interest is redirected, the user balance is added to the recepient redirected balance.
    * @param _to the address to which the interest will be redirected
    **/
    function redirectInterestStream(address _to) external {
        require(interestRedirectionAllowances[msg.sender] == address(0),'Administrator right is currently delegated to another account. Reset your administration right to be able to re-direct your Interest Stream.');
        redirectInterestStreamInternal(msg.sender, _to);
    }

    /**
    * @dev gives allowance to an address to execute the interest redirection on behalf of the caller.
    * @param _to the address to which the interest will be redirected. Pass address(0) to reset the allowance.
    **/
    function allowInterestRedirectionTo(address _to) external {
        require(_to != msg.sender, "User cannot give allowance to himself");
        interestRedirectionAllowances[msg.sender] = _to;
        emit InterestRedirectionAllowanceChanged( msg.sender, _to);
    }

    /**
    * @dev redirects the interest generated by _from to a target address.
    * The caller needs to have allowance on the interest redirection to be able to execute the function.
    * @param _from the address of the user whom interest is being redirected
    * @param _to the address to which the interest will be redirected
    **/
    function redirectInterestStreamOf(address _from, address _to) external {
        require( msg.sender == interestRedirectionAllowances[_from], "Caller is not allowed to redirect the interest of the user");
        redirectInterestStreamInternal(_from,_to);
    }


    /**
    * @dev executes the redirection of the interest from one address to another.
    * immediately after redirection, the destination address will start to accrue interest.
    * @param _from the address from which transfer the Itokens
    * @param _to the destination address
    **/
    function redirectInterestStreamInternal( address _from, address _to) internal {

        address currentRedirectionAddress = interestRedirectionAddresses[_from];
        require(_to != currentRedirectionAddress, "Interest is already redirected to the user");

        (uint256 previousPrincipalBalance, uint256 fromBalance, uint256 balanceIncrease, uint256 fromIndex) = cumulateBalanceInternal(_from);   //accumulates the accrued interest to the principal
        require(fromBalance > 0, "Interest stream can only be redirected if there is a valid balance");

        //if the user is already redirecting the interest to someone, before changing the redirection address we substract the redirected balance of the previous recipient
        if(currentRedirectionAddress != address(0)){
            updateRedirectedBalanceOfRedirectionAddressesInternal(_from,0, previousPrincipalBalance);
        }

        //if the user is redirecting the interest back to himself, we simply set to 0 the interest redirection address
        if(_to == _from) {
            interestRedirectionAddresses[_from] = address(0);
            emit InterestStreamRedirected( _from, address(0), fromBalance, balanceIncrease,fromIndex);
            return;
        }
        
        interestRedirectionAddresses[_from] = _to;      // set the redirection address to the new recipient
        updateRedirectedBalanceOfRedirectionAddressesInternal(_from,fromBalance,0);   //adds the user balance to the redirected balance of the destination

        emit InterestStreamRedirected( _from, _to, fromBalance, balanceIncrease, fromIndex);
    }

// ##################################################################################################################################
// ### cumulateBalanceInternal( user ) --> returns 4 values and mints the balanceIncrease amount  ###################################
// ###  1. previousPrincipalBalance : IToken balance of the user  ###################################################################
// ###  2. newPrincipalBalance : new balance after adding balanceIncrease  ##########################################################
// ###  3. balanceIncrease : increase in balance based on interest from both principal and redirected interest streams  #############
// ###  4. index : updated user Index (gets the value from the core lending pool contract)  #########################################
// ##################################################################################################################################

    function cumulateBalance(address _user) external onlySighStream returns(uint256, uint256, uint256, uint256) {
        cumulateBalanceInternal(_user); 
    }

    /**
    * @dev accumulates the accrued interest of the user to the principal balance
    * @param _user the address of the user for which the interest is being accumulated
    * @return the previous principal balance, the new principal balance, the balance increase
    * and the new user index
    **/
    function cumulateBalanceInternal(address _user) internal returns(uint256, uint256, uint256, uint256) {

        uint256 previousPrincipalBalance = super.balanceOf(_user);                                         // Current IToken Balance
        uint256 balanceIncrease = balanceOf(_user).sub(previousPrincipalBalance);                          //calculate the accrued interest since the last accumulation
        if (balanceIncrease > 0) {
            _mint(_user, balanceIncrease);                                                                     //mints an amount of tokens equivalent to the amount accumulated
        }
        uint256 index = userIndexes[_user] = core.getInstrumentNormalizedIncome(underlyingInstrumentAddress);      //updates the user index
        return ( previousPrincipalBalance, previousPrincipalBalance.add(balanceIncrease), balanceIncrease, index);
    }


// #########################################################################################################
// ### updateRedirectedBalanceOfRedirectionAddressesInternal( user ) --> updates the redirected balance of the user
// #########################################################################################################

    /**
    * @dev Updates the Interest / Liquidity $SIGH Stream Redirected Balances of the user. If the user is not redirecting anything, nothing is executed.
    * @param _user the address of the user for which the interest is being accumulated
    * @param _balanceToAdd the amount to add to the redirected balance
    * @param _balanceToRemove the amount to remove from the redirected balance
    **/
    function updateRedirectedBalanceOfRedirectionAddressesInternal( address _user, uint256 _balanceToAdd, uint256 _balanceToRemove ) internal {

        address redirectionAddress = interestRedirectionAddresses[_user];
        //if there isn't any redirection, nothing to be done
        if(redirectionAddress == address(0)){
            return;
        }

        //compound balances of the redirected address
        (,,uint256 balanceIncrease, ) = cumulateBalanceInternal(redirectionAddress);

        //updating the redirected balance
        redirectedBalances[redirectionAddress] = redirectedBalances[redirectionAddress].add(_balanceToAdd).sub(_balanceToRemove);

        //if the interest of redirectionAddress is also being redirected, we need to update
        //the redirected balance of the redirection target by adding the balance increase
        address targetOfRedirectionAddress = interestRedirectionAddresses[redirectionAddress];

        if(targetOfRedirectionAddress != address(0)){
            redirectedBalances[targetOfRedirectionAddress] = redirectedBalances[targetOfRedirectionAddress].add(balanceIncrease);
        }
        emit InterestRedirectedBalanceUpdated( redirectionAddress, _balanceToAdd, _balanceToRemove, redirectedBalances[redirectionAddress] );
    }



    /**
    * @dev calculate the interest accrued by _user on a specific balance
    * @param _user the address of the user for which the interest is being accumulated
    * @param _balance the balance on which the interest is calculated
    * @return the interest rate accrued
    **/
    function calculateCumulatedBalanceInternal( address _user,  uint256 _balance) internal view returns (uint256) {
        return _balance.wadToRay().rayMul(core.getInstrumentNormalizedIncome(underlyingInstrumentAddress)).rayDiv(userIndexes[_user]).rayToWad();
    }


// #################################################
// #### Called when the user balance becomes 0  ####
// #################################################
    /**
    * @dev function to reset the interest stream redirection and the user index, if the user has no balance left.
    * @param _user the address of the user
    * @return true if the user index has also been reset, false otherwise. useful to emit the proper user index value
    **/
    function resetDataOnZeroBalanceInternal(address _user) internal returns(bool) {
        
        interestRedirectionAddresses[_user] = address(0);       //if the user has 0 principal balance, the interest stream redirection gets reset
        emit InterestStreamRedirected(_user, address(0),0,0,0);     //emits a InterestStreamRedirected event to notify that the redirection has been reset

        //if the redirected balance is also 0, we clear up the user index
        if(redirectedBalances[_user] == 0){
            userIndexes[_user] = 0;
            return true;
        }
        else{
            return false;
        }
    }

// ############################################################
// #### Getting the State of the Contract (View Functions) ####
// ############################################################

    /**
    * @dev calculates the balance of the user, which is the principal balance + interest generated by the principal balance + interest generated by the redirected balance
    * @param _user the user for which the balance is being calculated
    * @return the total balance of the user
    **/
    function balanceOf(address _user) public view returns(uint256) {

        uint256 currentPrincipalBalance = super.balanceOf(_user);       //current principal balance of the user
        uint256 redirectedBalance = redirectedBalances[_user];          //balance redirected by other users to _user for interest rate accrual

        if(currentPrincipalBalance == 0 && redirectedBalance == 0) {
            return 0;
        }

        // current balance = prev balance + interest on (prev balance + redirected balance)
        if(interestRedirectionAddresses[_user] == address(0)){
            return calculateCumulatedBalanceInternal(_user, currentPrincipalBalance.add(redirectedBalance) ).sub(redirectedBalance);
        }
        // current balance = prev balance + interest on (redirected balance)
        else { 
            return currentPrincipalBalance.add( calculateCumulatedBalanceInternal( _user, redirectedBalance ).sub(redirectedBalance) );
        }
    }

    /**
    * @dev returns the principal balance of the user. The principal balance is the last updated stored balance, which does not consider the perpetually accruing interest.
    * @param _user the address of the user
    * @return the principal balance of the user
    **/
    function principalBalanceOf(address _user) external view returns(uint256) {
        return super.balanceOf(_user);
    }
    
    /**
    * @dev calculates the total supply of the specific Itoken. since the balance of every single user increases over time, the total supply does that too.
    * @return the current total supply
    **/
    function totalSupply() public view returns(uint256) {
        uint256 currentSupplyPrincipal = super.totalSupply();
        if(currentSupplyPrincipal == 0){
            return 0;
        }
        return currentSupplyPrincipal.wadToRay().rayMul( core.getInstrumentNormalizedIncome(underlyingInstrumentAddress) ).rayToWad();
    }

    /**
    * @dev returns the last index of the user, used to calculate the balance of the user
    * @param _user address of the user
    * @return the last user index
    **/
    function getUserIndex(address _user) external view returns(uint256) {
        return userIndexes[_user];
    }

    /**
    * @dev returns the address to which the interest is redirected
    * @param _user address of the user
    * @return 0 if there is no redirection, an address otherwise
    **/
    function getInterestRedirectionAddress(address _user) external view returns(address) {
        return interestRedirectionAddresses[_user];
    }

    /**
    * @dev returns the redirected balance of the user. The redirected balance is the balance redirected by other accounts to the user, that is accrueing interest for him.
    * @param _user address of the user
    * @return the total redirected balance
    **/
    function getRedirectedBalance(address _user) external view returns(uint256) {
        return redirectedBalances[_user];
    }


// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ######  ____ REDIRECTING Liquidity $SIGH STREAMS : FUNCTIONALITY ____     ##############################################################################################################
// ######  1. redirectLiquiditySIGHStream() [EXTERNAL] : User himself redirects his Liquidity SIGH stream.      #################################################################
// ######  2. allowLiquiditySIGHRedirectionTo() [EXTERNAL] : User gives the permission of redirecting the Liquidity SIGH stream to another account     ##########################
// ######  2. redirectLiquiditySIGHStreamOf() [EXTERNAL] : When account given the permission to redirect Liquidity SIGH stream (by the user) redirects the stream.    ###########
// ######  3. redirectLiquiditySIGHStreamInternal() [INTERNAL] --> Executes the redirecting of the Liquidity SIGH stream    #####################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################


    function redirectLiquiditySIGHStream(address _to) external {
        sighStream.redirectLiquiditySIGHStream(msg.sender, _to);
    }

    function allowLiquiditySIGHRedirectionTo(address _to) external {
        sighStream.allowLiquiditySIGHRedirectionTo(msg.sender,_to);
    }

    function redirectLiquiditySIGHStreamOf(address _from, address _to) external {
        sighStream.redirectLiquiditySIGHStreamOf(msg.sender, _from, _to );
    }


// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ######  ____ REDIRECTING Borrowing $SIGH STREAMS : FUNCTIONALITY ____     ##############################################################################################################
// ######  1. redirectBorrowingSIGHStream() [EXTERNAL] : User himself redirects his Borrowing SIGH Stream.      #################################################################
// ######  2. allowBorrowingSIGHRedirectionTo() [EXTERNAL] : User gives the permission of redirecting the Borrowing SIGH Stream to another account     ##########################
// ######  2. redirectBorrowingSIGHStreamOf() [EXTERNAL] : When account given the permission to redirect Borrowing SIGH Stream (by the user) redirects the stream.    ###########
// ######  3. redirectBorrowingSIGHStreamInternal() [INTERNAL] --> Executes the redirecting of the Borrowing SIGH Stream    #####################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################
// ###########################################################################################################################################################


    function redirectBorrowingSIGHStream(address _to) external {
        sighStream.redirectBorrowingSIGHStream(msg.sender, _to);
    }

    function allowBorrowingSIGHRedirectionTo(address _to) external {
        sighStream.allowBorrowingSIGHRedirectionTo(msg.sender, _to);
    }

    function redirectBorrowingSIGHStreamOf(address _from, address _to) external {
        sighStream.redirectBorrowingSIGHStreamOf(msg.sender, _from, _to);
    }


// ###########################################################################################################################################################
// ######  ____  Borrowing $SIGH StreamS : FUNCTIONALITY ____     ##############################################################################################################
// ######  1. updateRedirectedBalanceOfBorrowingSIGHStreamRedirectionAddress() : Addition / Subtraction from the redirected balance of the address to which the user's Borrowing $SIGH Stream is redirected      #################################################################
// ######  2. accure_SIGH_For_BorrowingStream() : Accure SIGH from the Borrowing $SIGH Streams     ##########################
// ###########################################################################################################################################################


    function updateRedirectedBalanceOfBorrowingSIGHStreamRedirectionAddress( address _user, uint256 _balanceToAdd, uint256 _balanceToRemove ) onlyLendingPoolCore external {
        sighStream.updateRedirectedBalanceOfBorrowingSIGHStreamRedirectionAddress(_user,_balanceToAdd,_balanceToRemove);
    }

    function accure_SIGH_For_BorrowingStream( address user) external onlyLendingPoolCore {
        sighStream.accure_SIGH_For_BorrowingStream(user);
    }


// ###############################################################################################################
// ###############################################################################################################
// ############ ______SIGH ACCURING AND STREAMING FUNCTIONS______ ################################################
// ############ 2. claimMySIGH() [EXTERNAL] : All accured SIGH is transferred to the transacting account.
// ############ 3. claimSIGH() [EXTERNAL]  : Accepts an array of users. Same as 1 but for array of users.
// ###############################################################################################################
// ###############################################################################################################


    function claimMySIGH() external {
        sighStream.claimMySIGH(msg.sender);
    }

    function claimSIGH(address[] calldata holders ) external {        
        for (uint i = 0; i < holders.length; i++) {
            sighStream.claimMySIGH(holders[i]);
        }
    }


// ###########################################################################
// ###########################################################################
// #############  VIEW FUNCTIONS ($SIGH STREAMS RELATED)    ################## 
// ###########################################################################
// ###########################################################################


    function getSighAccured(address account) external view returns (uint) {
        return sighStream.getSighAccured(account);
    }

    function getSIGHStreamsRedirectedTo(address user) external view returns (address liquiditySIGHStreamRedirectionAddress,address BorrowingSIGHStreamRedirectionAddress ) {
        (liquiditySIGHStreamRedirectionAddress, BorrowingSIGHStreamRedirectionAddress) = sighStream.getSIGHStreamsRedirectedTo(user);
    }

    function getSIGHStreamsAllowances(address user) external view returns (address liquiditySIGHStreamRedirectionAllowance,address BorrowingSIGHStreamRedirectionAllowance ) {
        (liquiditySIGHStreamRedirectionAllowance, BorrowingSIGHStreamRedirectionAllowance) = sighStream.getSIGHStreamsAllowances(user);
    }    

    function getSIGHStreamsIndexes(address user) external view returns (uint liquiditySIGHStreamIndex, uint borrowingSIGHStreamIndex) {
        (liquiditySIGHStreamIndex, borrowingSIGHStreamIndex) = sighStream.getSIGHStreamsIndexes(user);
    }    

    function getSIGHStreamsRedirectedBalances(address user) external view returns (uint liquiditySIGHStreamRedirectedBalance, uint borrowingSIGHStreamRedirectedBalance ) {
        (liquiditySIGHStreamRedirectedBalance, borrowingSIGHStreamRedirectedBalance) = sighStream.getSIGHStreamsRedirectedBalances(user);
    }    

}
