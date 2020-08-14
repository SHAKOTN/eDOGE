pragma solidity 0.5.16;

import "./Interfaces/IBorrowerOperations.sol";
import "./Interfaces/ICDPManager.sol";
import "./Interfaces/IPool.sol";
import "./Interfaces/IStabilityPool.sol";
import "./Interfaces/ICLVToken.sol";
import "./Interfaces/ISortedCDPs.sol";
import "./Interfaces/IPoolManager.sol";
import "./Interfaces/IPriceFeed.sol";
import "./Math.sol";
import "./Dependencies/LiquityBase.sol";
import "./Dependencies/Ownable.sol";
import "./Dependencies/ReentrancyGuard.sol";
import "./Dependencies/console.sol";

contract CDPManager is LiquityBase, ReentrancyGuard, Ownable, ICDPManager {

    uint constant public MCR = 1100000000000000000; // Minimal collateral ratio.
    uint constant public  CCR = 1500000000000000000; // Critical system collateral ratio. If the total system collateral (TCR) falls below the CCR, Recovery Mode is triggered.
    uint constant public MIN_VIRTUAL_DEBT = 10e18;   // The minimum virtual debt assigned to all troves: 10 CLV.

    // --- Connected contract declarations ---

    address public borrowerOperationsAddress;

    IPoolManager public poolManager;
    address public poolManagerAddress;

    IPool public activePool;
    address public activePoolAddress;

    IPool public defaultPool;
    address public defaultPoolAddress;

    ICLVToken public clvToken;
    address public clvTokenAddress;

    IPriceFeed public priceFeed;
    address public priceFeedAddress;

    IStabilityPool public stabilityPool;
    address public stabilityPoolAddress;

    // A doubly linked list of CDPs, sorted by their sorted by their collateral ratios
    ISortedCDPs public sortedCDPs;
    address public sortedCDPsAddress;

    // --- Data structures ---

    enum Status { nonExistent, active, closed }

    // Store the necessary data for a Collateralized Debt Position (CDP)
    struct CDP {
        uint debt;
        uint coll;
        uint stake;
        Status status;
        uint128 arrayIndex;
    }

    mapping (address => CDP) public CDPs;

    uint public totalStakes;

    // snapshot of the value of totalStakes immediately after the last liquidation
    uint public totalStakesSnapshot;

    // snapshot of the total collateral in ActivePool and DefaultPool, immediately after the last liquidation.
    uint public totalCollateralSnapshot;

    /* L_ETH and L_CLVDebt track the sums of accumulated liquidation rewards per unit staked. During it's lifetime, each stake earns:

    An ETH gain of ( stake * [L_ETH - L_ETH(0)] )
    A CLVDebt gain  of ( stake * [L_CLVDebt - L_CLVDebt(0)] )

    Where L_ETH(0) and L_CLVDebt(0) are snapshots of L_ETH and L_CLVDebt for the active CDP taken at the instant the stake was made */
    uint public L_ETH;
    uint public L_CLVDebt;

    // Map addresses with active CDPs to their RewardSnapshot
    mapping (address => RewardSnapshot) public rewardSnapshots;

    // Object containing the ETH and CLV snapshots for a given active CDP
    struct RewardSnapshot { uint ETH; uint CLVDebt;}

    // Array of all active CDP addresses - used to compute “approx hint” for list insertion
    address[] public CDPOwners;

    // Error trackers for the trove redistribution calculation
    uint public lastETHError_Redistribution;
    uint public lastCLVDebtError_Redistribution;

    /* --- Variable container structs for liquidations ---

    These structs are used to hold, return and assign variables inside the liquidation functions,
    in order to avoid the error: "CompilerError: Stack too deep". */

    struct LocalVariables_OuterLiquidationFunction {
        uint price;
        uint CLVInPool; 
        bool recoveryModeAtStart;
    }

    struct LocalVariables_InnerSingleLiquidateFunction {
        uint entireCDPDebt;
        uint entireCDPColl;
        uint collToLiquidate;
        uint pendingDebtReward;
        uint pendingCollReward;
    }

    struct LocalVariables_LiquidationSequence {
        uint remainingCLVInPool;
        uint i;
        uint ICR;
        address user;
        bool backToNormalMode;
        uint entireSystemDebt;
        uint entireSystemColl;
    }

    struct LocalVariables_BatchLiquidation {
        uint price;
        uint remainingCLVInPool;
        uint ICR;
        bool recoveryModeAtStart;
        bool backToNormalMode;
    }

    struct LiquidationValues {
        uint gasCompensation;
        uint debtToOffset;
        uint collToSendToSP;
        uint debtToRedistribute;
        uint collToRedistribute;
        address partialAddr;
        uint partialNewDebt;
        uint partialNewColl;
    }

    struct LiquidationTotals {
        uint totalGasCompensation;
        uint totalDebtToOffset;
        uint totalCollToSendToSP;
        uint totalDebtToRedistribute;
        uint totalCollToRedistribute;
        address partialAddr;
        uint partialNewDebt;
        uint partialNewColl;
    }

    // --- Variable container structs for redemptions ---

    struct RedemptionTotals {
        uint totalCLVtoRedeem;
        uint totalETHtoSend;
    }

    struct SingleRedemptionValues {
        uint CLVLot;
        uint ETHLot;
    }

    // --- Events ---

    event BorrowerOperationsAddressChanged(address _newBorrowerOperationsAddress);
    event PoolManagerAddressChanged(address _newPoolManagerAddress);
    event ActivePoolAddressChanged(address _activePoolAddress);
    event DefaultPoolAddressChanged(address _defaultPoolAddress);
    event StabilityPoolAddressChanged(address _stabilityPoolAddress);
    event PriceFeedAddressChanged(address  _newPriceFeedAddress);
    event CLVTokenAddressChanged(address _newCLVTokenAddress);
    event SortedCDPsAddressChanged(address _sortedCDPsAddress);
    event SizeListAddressChanged(uint _sizeRange, address _sizeListAddress);

    enum CDPManagerOperation {
        applyPendingRewards,
        liquidateInNormalMode,
        liquidateInRecoveryMode,
        partiallyLiquidateInRecoveryMode,
        redeemCollateral
    }

    event CDPCreated(address indexed _user, uint arrayIndex);
    event CDPUpdated(address indexed _user, uint _debt, uint _coll, uint stake, CDPManagerOperation operation);

    // --- Modifiers ---

    modifier onlyBorrowerOperations() {
        require(_msgSender() == borrowerOperationsAddress, "CDPManager: Caller is not the BorrowerOperations contract");
        _;
    }

    // --- Dependency setters ---

    function setBorrowerOperations(address _borrowerOperationsAddress) external onlyOwner {
        borrowerOperationsAddress = _borrowerOperationsAddress;
        emit BorrowerOperationsAddressChanged(_borrowerOperationsAddress);
    }

    function setPoolManager(address _poolManagerAddress) external onlyOwner {
        poolManagerAddress = _poolManagerAddress;
        poolManager = IPoolManager(_poolManagerAddress);
        emit PoolManagerAddressChanged(_poolManagerAddress);
    }

    function setActivePool(address _activePoolAddress) external onlyOwner {
        activePoolAddress = _activePoolAddress;
        activePool = IPool(_activePoolAddress);
        emit ActivePoolAddressChanged(_activePoolAddress);
    }

    function setDefaultPool(address _defaultPoolAddress) external onlyOwner {
        defaultPoolAddress = _defaultPoolAddress;
        defaultPool = IPool(_defaultPoolAddress);
        emit DefaultPoolAddressChanged(_defaultPoolAddress);
    }

    function setStabilityPool(address _stabilityPoolAddress) external onlyOwner {
        stabilityPoolAddress = _stabilityPoolAddress;
        stabilityPool = IStabilityPool(_stabilityPoolAddress);
        emit StabilityPoolAddressChanged(_stabilityPoolAddress);
    }

    function setPriceFeed(address _priceFeedAddress) external onlyOwner {
        priceFeedAddress = _priceFeedAddress;
        priceFeed = IPriceFeed(priceFeedAddress);
        emit PriceFeedAddressChanged(_priceFeedAddress);
    }

    function setCLVToken(address _clvTokenAddress) external onlyOwner {
        clvTokenAddress = _clvTokenAddress;
        clvToken = ICLVToken(_clvTokenAddress);
        emit CLVTokenAddressChanged(_clvTokenAddress);
    }

    function setSortedCDPs(address _sortedCDPsAddress) external onlyOwner {
        sortedCDPsAddress = _sortedCDPsAddress;
        sortedCDPs = ISortedCDPs(_sortedCDPsAddress);
        emit SortedCDPsAddressChanged(_sortedCDPsAddress);
    }

    // --- Getters ---

    function getCDPOwnersCount() external view returns (uint) {
        return CDPOwners.length;
    }

    function getTroveFromCDPOwnersArray(uint _index) external view returns (address) {
        return CDPOwners[_index];
    }

    // --- CDP Liquidation functions ---

    // Closes the CDP of the specified user if its individual collateral ratio is lower than the minimum collateral ratio.
    function liquidate(address _user) external {
        _requireCDPisActive(_user);

        LocalVariables_OuterLiquidationFunction memory L;
        L.price = priceFeed.getPrice();
        L.CLVInPool = stabilityPool.getCLV();
        L.recoveryModeAtStart = _checkRecoveryMode();

        uint ICR = _getCurrentICR(_user, L.price);

        LiquidationValues memory V;

        V = (L.recoveryModeAtStart == true)
            ? _liquidateRecoveryMode(_user, ICR, L.price, L.CLVInPool)
            : _liquidateNormalMode(_user, ICR, L.price, L.CLVInPool);

        poolManager.offset(V.debtToOffset, V.collToSendToSP);
        _redistributeDebtAndColl(V.debtToRedistribute, V.collToRedistribute);

        _updateSystemSnapshots_excludeCollRemainder(V.partialNewColl);
        _updatePartiallyLiquidatedTrove(V.partialAddr,
                                        V.partialNewDebt,
                                        V.partialNewColl,
                                        L.price);

        // Send gas compensation ETH to caller
        (bool success, ) = _msgSender().call.value(V.gasCompensation)("");
        _requireETHSentSuccessfully(success);
    }

    function _liquidateNormalMode(address _user, uint _ICR, uint _price, uint _CLVInPool) internal
    returns (LiquidationValues memory V)
    {
        LocalVariables_InnerSingleLiquidateFunction memory L;

        // If ICR >= MCR, or is last trove, don't liquidate
        if (_ICR >= MCR || CDPOwners.length <= 1) {return V;}

        (L.entireCDPDebt,
        L.entireCDPColl,
        L.pendingDebtReward,
        L.pendingCollReward) = _getEntireDebtAndColl(_user);

        poolManager.movePendingTroveRewardsToActivePool(L.pendingDebtReward, L.pendingCollReward);
        _removeStake(_user);

        V.gasCompensation = _getGasCompensation(L.entireCDPColl, _price);
        uint collToLiquidate = L.entireCDPColl.sub(V.gasCompensation);

        (V.debtToOffset,
        V.collToSendToSP,
        V.debtToRedistribute,
        V.collToRedistribute) = _getOffsetAndRedistributionVals(L.entireCDPDebt, collToLiquidate, _CLVInPool);

        // Move the gas compensation ETH to the CDPManager
        activePool.sendETH(address(this), V.gasCompensation);

        _closeCDP(_user);
        emit CDPUpdated(_user, 0, 0, 0, CDPManagerOperation.liquidateInNormalMode);

        return V;
    }

    function _liquidateRecoveryMode(address _user, uint _ICR, uint _price, uint _CLVInPool) internal
    returns (LiquidationValues memory V)
    {
        LocalVariables_InnerSingleLiquidateFunction memory L;
        // If is last trove, don't liquidate
        if (CDPOwners.length <= 1) {return V;}

        (L.entireCDPDebt,
        L.entireCDPColl,
        L.pendingDebtReward,
        L.pendingCollReward) = _getEntireDebtAndColl(_user);

        V.gasCompensation = _getGasCompensation(L.entireCDPColl, _price);
        L.collToLiquidate = L.entireCDPColl.sub(V.gasCompensation);

        // If ICR <= 100%, purely redistribute the CDP across all active CDPs
        if (_ICR <= 1000000000000000000) {
            poolManager.movePendingTroveRewardsToActivePool(L.pendingDebtReward, L.pendingCollReward);
            _removeStake(_user);

            V.debtToOffset = 0;
            V.collToSendToSP = 0;
            V.debtToRedistribute = L.entireCDPDebt;
            V.collToRedistribute = L.collToLiquidate;

            _closeCDP(_user);
            emit CDPUpdated(_user, 0, 0, 0, CDPManagerOperation.liquidateInRecoveryMode);

        // if 100% < ICR < MCR, offset as much as possible, and redistribute the remainder
        } else if ((_ICR > 1000000000000000000) && (_ICR < MCR)) {
             poolManager.movePendingTroveRewardsToActivePool(L.pendingDebtReward, L.pendingCollReward);
            _removeStake(_user);

            (V.debtToOffset,
            V.collToSendToSP,
            V.debtToRedistribute,
            V.collToRedistribute) = _getOffsetAndRedistributionVals(L.entireCDPDebt, L.collToLiquidate, _CLVInPool);

            _closeCDP(_user);
            emit CDPUpdated(_user, 0, 0, 0, CDPManagerOperation.liquidateInRecoveryMode);

        // If CDP has the lowest ICR and there is CLV in the Stability Pool, only offset it as much as possible (no redistribution)
        } else if (_user == sortedCDPs.getLast()) {

            if (_CLVInPool == 0) {return V;}
            _applyPendingRewards(_user);
            _removeStake(_user);

            V = _getPartialOffsetVals(_user, L.entireCDPDebt, L.entireCDPColl, _price, _CLVInPool);

            _closeCDP(_user);
        }

        // Move the gas compensation ETH to the CDPManager
        activePool.sendETH(address(this), V.gasCompensation);

        return V;
    }

    function _getOffsetAndRedistributionVals(uint _debt, uint _coll, uint _CLVInPool) internal pure
    returns (uint debtToOffset, uint collToSendToSP, uint debtToRedistribute, uint collToRedistribute)
    {
         // Offset as much debt & collateral as possible against the Stability Pool, and redistribute the remainder
        if (_CLVInPool > 0) {
        /* If the debt is larger than the deposited CLV, offset an amount of debt equal to the latter,
        and send collateral in proportion to the cancelled debt */
            debtToOffset = Math._min(_debt, _CLVInPool);
            collToSendToSP = _coll.mul(debtToOffset).div(_debt);
            debtToRedistribute = _debt.sub(debtToOffset);
            collToRedistribute = _coll.sub(collToSendToSP);
        } else {
            debtToOffset = 0;
            collToSendToSP = 0;
            debtToRedistribute = _debt;
            collToRedistribute = _coll;
        }
    }

    function _getPartialOffsetVals(address _user, uint _entireCDPDebt, uint _entireCDPColl, uint _price, uint _CLVInPool) internal
    returns
    (LiquidationValues memory V) {
        // When Pool can fully absorb the trove's debt, perform a full offset
        if (_entireCDPDebt < _CLVInPool) {
            V.gasCompensation = _getGasCompensation(_entireCDPColl, _price);

            V.debtToOffset = _entireCDPDebt;
            V.collToSendToSP = _entireCDPColl.sub(V.gasCompensation);
            V.debtToRedistribute = 0;
            V.collToRedistribute = 0;

            emit CDPUpdated(_user, 0, 0, 0, CDPManagerOperation.liquidateInRecoveryMode);
        }
        /* When trove's debt is greater than the Pool, perform a partial liquidation:
        offset as much as possible, and do not redistribute the remainder.
        Gas compensation is based on and drawn from the collateral fraction that corresponds to the partial offset. */
        else if (_entireCDPDebt > _CLVInPool) {
            V.debtToOffset = _CLVInPool;
            uint collFraction = _entireCDPColl.mul(V.debtToOffset).div(_entireCDPDebt);
            V.gasCompensation = _getGasCompensation(collFraction, _price);
            
            V.collToSendToSP = collFraction.sub(V.gasCompensation);
            V.collToRedistribute = 0;
            V.debtToRedistribute = 0;

            V.partialAddr = _user;
            V.partialNewDebt = _entireCDPDebt.sub(V.debtToOffset);
            V.partialNewColl = _entireCDPColl.sub(collFraction);
        }
    }

    // Closes a maximum number of n multiple under-collateralized CDPs, starting from the one with the lowest collateral ratio
    function liquidateCDPs(uint _n) external {
        LocalVariables_OuterLiquidationFunction memory L;

        LiquidationTotals memory T;

        L.price = priceFeed.getPrice();
        L.CLVInPool = stabilityPool.getCLV();
        L.recoveryModeAtStart = _checkRecoveryMode();
     
        // Perform the appropriate liquidation sequence - tally values and obtain their totals
        if (L.recoveryModeAtStart == true) {
           T = _getTotalFromLiquidationSequence_RecoveryMode(L.price, L.CLVInPool, _n);
        } else if (L.recoveryModeAtStart == false) {
            T = _getTotalsFromLiquidationSequence_NormalMode(L.price, L.CLVInPool, _n);
        }

        // Move liquidated ETH and CLV to the appropriate pools
        poolManager.offset(T.totalDebtToOffset, T.totalCollToSendToSP);
        _redistributeDebtAndColl(T.totalDebtToRedistribute, T.totalCollToRedistribute);

        // Update system snapshots and the final partially liquidatedtrove, if there is one
        _updateSystemSnapshots_excludeCollRemainder(T.partialNewColl);
        _updatePartiallyLiquidatedTrove(T.partialAddr,
                                        T.partialNewDebt,
                                        T.partialNewColl,
                                        L.price);

        // Send gas compensation ETH to caller
        (bool success, ) = _msgSender().call.value(T.totalGasCompensation)("");
        _requireETHSentSuccessfully(success);
    }

    function _getTotalFromLiquidationSequence_RecoveryMode(uint _price, uint _CLVInPool, uint _n) internal 
    returns(LiquidationTotals memory T)
    {
        LocalVariables_LiquidationSequence memory L;
        LiquidationValues memory V;

        L.remainingCLVInPool = _CLVInPool;
        L.backToNormalMode = false;
        L.entireSystemDebt = activePool.getCLVDebt().add(defaultPool.getCLVDebt());
        L.entireSystemColl = activePool.getETH().add(defaultPool.getETH());

        L.i = 0;
        while (L.i < _n) {
            L.user = sortedCDPs.getLast();
            L.ICR = _getCurrentICR(L.user, _price);

            // Attempt to close CDP
            if (L.backToNormalMode == false) {

                V = _liquidateRecoveryMode(L.user, L.ICR, _price, L.remainingCLVInPool);

                // Update aggregate trackers
                L.remainingCLVInPool = L.remainingCLVInPool.sub(V.debtToOffset);
                L.entireSystemDebt = L.entireSystemDebt.sub(V.debtToOffset);
                L.entireSystemColl = L.entireSystemColl.sub(V.collToSendToSP);

                // Add liquidation values to their respective running totals
                T = _addLiquidationValuesToTotals(T, V);

                L.backToNormalMode = !_checkPotentialRecoveryMode(L.entireSystemColl, L.entireSystemDebt, _price);
            }
            else if (L.backToNormalMode == true && L.ICR < MCR) {
                V = _liquidateNormalMode(L.user, L.ICR, _price, L.remainingCLVInPool);

                L.remainingCLVInPool = L.remainingCLVInPool.sub(V.debtToOffset);

                // Add liquidation values to their respective running totals
                T = _addLiquidationValuesToTotals(T, V);

            }  else break;  // break if the loop reaches a CDP with ICR >= MCR

            // Break the loop if it has reached the first CDP in the sorted list
            if (L.user == sortedCDPs.getFirst()) {break;}
            L.i++;
        }
    }

    function _getTotalsFromLiquidationSequence_NormalMode(uint _price, uint _CLVInPool, uint _n) internal 
    returns(LiquidationTotals memory T)
    {
        LocalVariables_LiquidationSequence memory L;
        LiquidationValues memory V;

        L.remainingCLVInPool = _CLVInPool;

        L.i = 0;
        while (L.i < _n) {
            L.user = sortedCDPs.getLast();
            L.ICR = _getCurrentICR(L.user, _price);
            
            if (L.ICR < MCR) {
                V = _liquidateNormalMode(L.user, L.ICR, _price, L.remainingCLVInPool);

                L.remainingCLVInPool = L.remainingCLVInPool.sub(V.debtToOffset);

                // Add liquidation values to their respective running totals
                T = _addLiquidationValuesToTotals(T, V);

            } else break;  // break if the loop reaches a CDP with ICR >= MCR
            
            // Break the loop if it reaches the first CDP in the sorted list
            if (L.user == sortedCDPs.getFirst()) {break;}
            L.i++;
        }
    }

    function batchLiquidateTroves(address[] calldata _troveArray) external {
        require(_troveArray.length != 0, "CDPManager: Calldata address array must not be empty");
        
        LocalVariables_OuterLiquidationFunction memory L;
        LiquidationTotals memory T;

        L.price = priceFeed.getPrice();
        L.CLVInPool = stabilityPool.getCLV();
        L.recoveryModeAtStart = _checkRecoveryMode();
        
        // Perform the appropriate liquidation sequence - tally values and obtain their totals
        if (L.recoveryModeAtStart == true) {
           T = _getTotalFromBatchLiquidate_RecoveryMode(L.price, L.CLVInPool, _troveArray);
        } else if (L.recoveryModeAtStart == false) {
            T = _getTotalsFromBatchLiquidate_NormalMode(L.price, L.CLVInPool, _troveArray);
        }

        // Move liquidated ETH and CLV to the appropriate pools
        poolManager.offset(T.totalDebtToOffset, T.totalCollToSendToSP);
        _redistributeDebtAndColl(T.totalDebtToRedistribute, T.totalCollToRedistribute);

        // Update system snapshots and the final partially liquidated trove, if there is one
        _updateSystemSnapshots_excludeCollRemainder(T.partialNewColl);
        _updatePartiallyLiquidatedTrove(T.partialAddr,
                                        T.partialNewDebt,
                                        T.partialNewColl,
                                        L.price);

        // Send gas compensation ETH to caller
        (bool success, ) = _msgSender().call.value(T.totalGasCompensation)("");
        _requireETHSentSuccessfully(success);
    }

    function _getTotalFromBatchLiquidate_RecoveryMode(uint _price, uint _CLVInPool, address[] memory _troveArray) internal 
    returns(LiquidationTotals memory T)
    {
        LocalVariables_LiquidationSequence memory L;
        LiquidationValues memory V;
        uint troveArrayLength = _troveArray.length;

        L.remainingCLVInPool = _CLVInPool;
        L.backToNormalMode = false;
        L.entireSystemDebt = activePool.getCLVDebt().add(defaultPool.getCLVDebt());
        L.entireSystemColl = activePool.getETH().add(defaultPool.getETH());

        L.i = 0;
         for (L.i = 0; L.i < troveArrayLength; L.i++) {
             L.user = _troveArray[L.i];
            L.ICR = _getCurrentICR(L.user, _price);

            // Attempt to close CDP
            if (L.backToNormalMode == false) {
                V = _liquidateRecoveryMode(L.user, L.ICR, _price, L.remainingCLVInPool);

                // Update aggregate trackers
                L.remainingCLVInPool = L.remainingCLVInPool.sub(V.debtToOffset);
                L.entireSystemDebt = L.entireSystemDebt.sub(V.debtToOffset);
                L.entireSystemColl = L.entireSystemColl.sub(V.collToSendToSP);

                // Add liquidation values to their respective running totals
                T = _addLiquidationValuesToTotals(T, V);

                L.backToNormalMode = !_checkPotentialRecoveryMode(L.entireSystemColl, L.entireSystemDebt, _price);
            }
            else if (L.backToNormalMode == true && L.ICR < MCR) {
                V = _liquidateNormalMode(L.user, L.ICR, _price, L.remainingCLVInPool);
                L.remainingCLVInPool = L.remainingCLVInPool.sub(V.debtToOffset);

                // Add liquidation values to their respective running totals
                T = _addLiquidationValuesToTotals(T, V);
            }  
        }
    }

    function _getTotalsFromBatchLiquidate_NormalMode(uint _price, uint _CLVInPool, address[] memory _troveArray) internal 
    returns(LiquidationTotals memory T)
    {
        LocalVariables_LiquidationSequence memory L;
        LiquidationValues memory V;
        uint troveArrayLength = _troveArray.length;

        L.remainingCLVInPool = _CLVInPool;
        
        for (L.i = 0; L.i < troveArrayLength; L.i++) {
            L.user = _troveArray[L.i];
            L.ICR = _getCurrentICR(L.user, _price);
            
            if (L.ICR < MCR) {
                V = _liquidateNormalMode(L.user, L.ICR, _price, L.remainingCLVInPool);
                L.remainingCLVInPool = L.remainingCLVInPool.sub(V.debtToOffset);

                // Add liquidation values to their respective running totals
                T = _addLiquidationValuesToTotals(T, V);
            }
        }
    } 

    function _addLiquidationValuesToTotals(LiquidationTotals memory T1, LiquidationValues memory V) 
    internal pure returns(LiquidationTotals memory T2) {

        // Tally gas compensation
        T2.totalGasCompensation = T1.totalGasCompensation.add(V.gasCompensation);

        // Tally the debt and coll to offset and redistribute
        T2.totalDebtToOffset = T1.totalDebtToOffset.add(V.debtToOffset);
        T2.totalCollToSendToSP = T1.totalCollToSendToSP.add(V.collToSendToSP);
        T2.totalDebtToRedistribute = T1.totalDebtToRedistribute.add(V.debtToRedistribute);
        T2.totalCollToRedistribute =T1.totalCollToRedistribute .add(V.collToRedistribute);

        // Assign the address of the ppartially liquidated trove and debt/coll values
        T2.partialAddr = V.partialAddr;
        T2.partialNewDebt = V.partialNewDebt;
        T2.partialNewColl = V.partialNewColl;

        return T2;
    }

    // Update coll, debt, stake and snapshot of partially liquidated trove, and insert it back to the list
    function _updatePartiallyLiquidatedTrove(address _user, uint _newDebt, uint _newColl, uint _price) internal {
        if ( _user == address(0)) { return; }

        CDPs[_user].debt = _newDebt;
        CDPs[_user].coll = _newColl;
        CDPs[_user].status = Status.active;
    
        _updateCDPRewardSnapshots(_user);
        _updateStakeAndTotalStakes(_user);

        uint ICR = _getCurrentICR(_user, _price);

        // Insert to full sorted list
        sortedCDPs.insert(_user, ICR, _price, _user, _user);
        emit CDPUpdated(_user, _newDebt, _newColl, CDPs[_user].stake, CDPManagerOperation.partiallyLiquidateInRecoveryMode);
    }

    // --- Redemption functions ---

    // Redeem as much collateral as possible from _cdpUser's CDP in exchange for CLV up to _maxCLVamount
    function _redeemCollateralFromCDP(
        address _cdpUser,
        uint _maxCLVamount,
        uint _price,
        address _partialRedemptionHint,
        uint _partialRedemptionHintICR
    )
        internal returns (SingleRedemptionValues memory V)
    {
        // Determine the remaining amount (lot) to be redeemed, capped by the entire debt of the CDP
        V.CLVLot = Math._min(_maxCLVamount, CDPs[_cdpUser].debt);
        
        // Get the ETHLot of equivalent value in USD
        V.ETHLot = V.CLVLot.mul(1e18).div(_price);
        
        // Decrease the debt and collateral of the current CDP according to the CLV lot and corresponding ETH to send
        uint newDebt = (CDPs[_cdpUser].debt).sub(V.CLVLot);
        uint newColl = (CDPs[_cdpUser].coll).sub(V.ETHLot);

        if (newDebt == 0) {
            // No debt left in the CDP, therefore new ICR must be "infinite".
            // Passing zero as hint will cause sortedCDPs to descend the list from the head, which is the correct insert position.
            sortedCDPs.reInsert(_cdpUser, 2**256 - 1, _price, address(0), address(0));
        } else {
            uint compositeDebt = _getCompositeDebt(newDebt);
            uint newICR = Math._computeCR(newColl, compositeDebt, _price);

            // Check if the provided hint is fresh. If not, we bail since trying to reinsert without a good hint will almost
            // certainly result in running out of gas.
            if (newICR != _partialRedemptionHintICR) {
                V.CLVLot = 0;
                V.ETHLot = 0;
                return V;
            }

            sortedCDPs.reInsert(_cdpUser, newICR, _price, _partialRedemptionHint, _partialRedemptionHint);
        }

        CDPs[_cdpUser].debt = newDebt;
        CDPs[_cdpUser].coll = newColl;
        _updateStakeAndTotalStakes(_cdpUser);

        // Burn the calculated lot of CLV and send the corresponding ETH to _msgSender()
        // poolManager.redeemCollateral(_msgSender(), CLVLot, ETHLot); 

        emit CDPUpdated(
                        _cdpUser,
                        newDebt,
                        newColl,
                        CDPs[_cdpUser].stake,
                        CDPManagerOperation.redeemCollateral
                        ); 

        return V;
    }

    function _isValidFirstRedemptionHint(address _firstRedemptionHint, uint _price) internal view returns (bool) {
        if (_firstRedemptionHint == address(0) ||
            !sortedCDPs.contains(_firstRedemptionHint) ||
            _getCurrentICR(_firstRedemptionHint, _price) < MCR
        ) {
            return false;
        }

        address nextCDP = sortedCDPs.getNext(_firstRedemptionHint);
        return nextCDP == address(0) || _getCurrentICR(nextCDP, _price) < MCR;
    }

    /* Send _CLVamount CLV to the system and redeem the corresponding amount of collateral from as many CDPs as are needed to fill the redemption
     request.  Applies pending rewards to a CDP before reducing its debt and coll.

    Note that if _amount is very large, this function can run out of gas. This can be easily avoided by splitting the total _amount
    in appropriate chunks and calling the function multiple times.

    All CDPs that are redeemed from -- with the likely exception of the last one -- will end up with no debt left, therefore they will be
    reinsterted at the top of the sortedCDPs list. If the last CDP does have some remaining debt, the reinsertion could be anywhere in the
    list, therefore it requires a hint. A frontend should use getRedemptionHints() to calculate what the ICR of this CDP will be
    after redemption, and pass a hint for its position in the sortedCDPs list along with the ICR value that the hint was found for.

    If another transaction modifies the list between calling getRedemptionHints() and passing the hints to redeemCollateral(), it
    is very likely that the last (partially) redeemed CDP would end up with a different ICR than what the hint is for. In this case the
    redemption will stop after the last completely redeemed CDP and the sender will keep the remaining CLV amount, which they can attempt
    to redeem later.
     */
    function redeemCollateral(
        uint _CLVamount,
        address _firstRedemptionHint,
        address _partialRedemptionHint,
        uint _partialRedemptionHintICR
    )
    nonReentrant external
    {
        address redeemer = _msgSender();
        uint activeDebt = activePool.getCLVDebt();
        uint defaultedDebt = defaultPool.getCLVDebt();

        RedemptionTotals memory T;

        _requireCLVBalanceCoversRedemption(redeemer, _CLVamount);
        
        // Confirm redeemer's balance is less than total systemic debt
        assert(clvToken.balanceOf(redeemer) <= (activeDebt.add(defaultedDebt)));

        uint remainingCLV = _CLVamount;
        uint price = priceFeed.getPrice();
        address currentCDPuser;

        if (_isValidFirstRedemptionHint(_firstRedemptionHint, price)) {
            currentCDPuser = _firstRedemptionHint;
        } else {
            currentCDPuser = sortedCDPs.getLast();

            while (currentCDPuser != address(0) && _getCurrentICR(currentCDPuser, price) < MCR) {
                currentCDPuser = sortedCDPs.getPrev(currentCDPuser);
            }
        }

        // Loop through the CDPs starting from the one with lowest collateral ratio until _amount of CLV is exchanged for collateral
        while (currentCDPuser != address(0) && remainingCLV > 0) {
            // Save the address of the CDP preceding the current one, before potentially modifying the list
            address nextUserToCheck = sortedCDPs.getPrev(currentCDPuser);

            _applyPendingRewards(currentCDPuser);

            SingleRedemptionValues memory V = _redeemCollateralFromCDP(
                currentCDPuser,
                remainingCLV,
                price,
                _partialRedemptionHint,
                _partialRedemptionHintICR
            );

            if (V.CLVLot == 0) break; // Partial redemption hint got out-of-date, therefore we could not redeem from the last CDP

            T.totalCLVtoRedeem  = T.totalCLVtoRedeem.add(V.CLVLot);
            T.totalETHtoSend = T.totalETHtoSend.add(V.ETHLot);
            
            remainingCLV = remainingCLV.sub(V.CLVLot);
            currentCDPuser = nextUserToCheck;
        }

        // Burn the total CLV redeemed from troves, and send the corresponding ETH to _msgSender()
        poolManager.redeemCollateral(_msgSender(), T.totalCLVtoRedeem, T.totalETHtoSend); 
    }

    // --- Helper functions ---

    function getCurrentICR(address _user, uint _price) external view returns (uint) {
        return _getCurrentICR(_user, _price);
    }

    // Return the current collateral ratio (ICR) of a given CDP. Takes pending coll/debt rewards into account.
    function _getCurrentICR(address _user, uint _price) internal view returns (uint) {
        uint pendingETHReward = _computePendingETHReward(_user); 
        uint pendingCLVDebtReward = _computePendingCLVDebtReward(_user); 
        
        uint currentETH = CDPs[_user].coll.add(pendingETHReward); 
        uint currentCLVDebt = CDPs[_user].debt.add(pendingCLVDebtReward); 

        uint compositeCLVDebt = _getCompositeDebt(currentCLVDebt);
       
        uint ICR = Math._computeCR(currentETH, compositeCLVDebt, _price);  
        return ICR;
    }

    function applyPendingRewards(address _user) external onlyBorrowerOperations {
        return _applyPendingRewards(_user);
    }

    // Add the user's coll and debt rewards earned from liquidations, to their CDP
    function _applyPendingRewards(address _user) internal {
        if (_hasPendingRewards(_user)) { 
        
            _requireCDPisActive(_user);

            // Compute pending rewards
            uint pendingETHReward = _computePendingETHReward(_user); 
            uint pendingCLVDebtReward = _computePendingCLVDebtReward(_user);  

            // Apply pending rewards to trove's state
            CDPs[_user].coll = CDPs[_user].coll.add(pendingETHReward);  
            CDPs[_user].debt = CDPs[_user].debt.add(pendingCLVDebtReward); 

            _updateCDPRewardSnapshots(_user);

            // Tell PM to transfer from DefaultPool to ActivePool
            poolManager.movePendingTroveRewardsToActivePool(pendingCLVDebtReward, pendingETHReward);

            emit CDPUpdated(_user, CDPs[_user].debt, CDPs[_user].coll, CDPs[_user].stake, CDPManagerOperation.applyPendingRewards);
        }
    }

    // Update user's snapshots of L_ETH and L_CLVDebt to reflect the current values
    function updateCDPRewardSnapshots(address _user) external onlyBorrowerOperations {
       return  _updateCDPRewardSnapshots(_user);
    }

    function _updateCDPRewardSnapshots(address _user) internal {
        rewardSnapshots[_user].ETH = L_ETH; 
        rewardSnapshots[_user].CLVDebt = L_CLVDebt; 
    }
    
    function getPendingETHReward(address _user) external view returns (uint) {
        return _computePendingETHReward(_user);
    }

    // Get the user's pending accumulated ETH reward, earned by its stake
    function _computePendingETHReward(address _user) internal view returns (uint) {
        uint snapshotETH = rewardSnapshots[_user].ETH; 
        uint rewardPerUnitStaked = L_ETH.sub(snapshotETH); 
        
        if ( rewardPerUnitStaked == 0 ) { return 0; }
       
        uint stake = CDPs[_user].stake;
        
        uint pendingETHReward = stake.mul(rewardPerUnitStaked).div(1e18);

        return pendingETHReward;
    }

    function getPendingCLVDebtReward(address _user) external view returns (uint) {
        return _computePendingCLVDebtReward(_user);
    }

     // Get the user's pending accumulated CLV reward, earned by its stake
    function _computePendingCLVDebtReward(address _user) internal view returns (uint) {
        uint snapshotCLVDebt = rewardSnapshots[_user].CLVDebt;  
        uint rewardPerUnitStaked = L_CLVDebt.sub(snapshotCLVDebt); 
       
        if ( rewardPerUnitStaked == 0 ) { return 0; }
       
        uint stake =  CDPs[_user].stake; 
      
        uint pendingCLVDebtReward = stake.mul(rewardPerUnitStaked).div(1e18);
     
        return pendingCLVDebtReward;
    }

    function hasPendingRewards(address _user) public view returns (bool) {
        require(uint(CDPs[_user].status) == 1, "CDPManager: User does not have an active trove");
        return _hasPendingRewards(_user);
    }
    
    function _hasPendingRewards(address _user) internal view returns (bool) {
        /* A CDP has pending rewards if its snapshot is less than the current rewards per-unit-staked sum.
        If so, this indicates that rewards have occured since the snapshot was made, and the user therefore has
        pending rewards */
        return (rewardSnapshots[_user].ETH < L_ETH);
    }

     // Returns the CDPs entire debt and coll, including distribution pending rewards.
    function _getEntireDebtAndColl(address _user) 
    internal view
    returns (uint debt, uint coll, uint pendingCLVDebtReward, uint pendingETHReward)
    {
        debt = CDPs[_user].debt;
        coll = CDPs[_user].coll;

        if (_hasPendingRewards(_user)) {
            pendingCLVDebtReward = _computePendingCLVDebtReward(_user);
            pendingETHReward = _computePendingETHReward(_user);

            debt = debt.add(pendingCLVDebtReward);
            coll = coll.add(pendingETHReward);
        }
    }

    function removeStake(address _user) external onlyBorrowerOperations {
        return _removeStake(_user);
    }

    // Remove use's stake from the totalStakes sum, and set their stake to 0
    function _removeStake(address _user) internal {
        uint stake = CDPs[_user].stake;
        totalStakes = totalStakes.sub(stake);
        CDPs[_user].stake = 0;
    }

    function updateStakeAndTotalStakes(address _user) external onlyBorrowerOperations returns (uint) {
        return _updateStakeAndTotalStakes(_user);
    }

    // Update user's stake based on their latest collateral value
    function _updateStakeAndTotalStakes(address _user) internal returns (uint) {
        uint newStake = _computeNewStake(CDPs[_user].coll); 
        uint oldStake = CDPs[_user].stake;
        CDPs[_user].stake = newStake;
        totalStakes = totalStakes.sub(oldStake).add(newStake);

        return newStake;
    }

    function _computeNewStake(uint _coll) internal view returns (uint) {
        uint stake;
        if (totalCollateralSnapshot == 0) {
            stake = _coll;
        } else {
            stake = _coll.mul(totalStakesSnapshot).div(totalCollateralSnapshot);
        }
     return stake;
    }

    function _redistributeDebtAndColl(uint _debt, uint _coll) internal {
        if (_debt == 0) { return; }
        
        if (totalStakes > 0) {
            // Add distributed coll and debt rewards-per-unit-staked to the running totals.
            
            // Division with correction
            uint ETHNumerator = _coll.mul(1e18).add(lastETHError_Redistribution);
            uint CLVDebtNumerator = _debt.mul(1e18).add(lastCLVDebtError_Redistribution);

            uint ETHRewardPerUnitStaked = ETHNumerator.div(totalStakes);
            uint CLVDebtRewardPerUnitStaked = CLVDebtNumerator.div(totalStakes);

            lastETHError_Redistribution = ETHNumerator.sub(ETHRewardPerUnitStaked.mul(totalStakes));
            lastCLVDebtError_Redistribution = CLVDebtNumerator.sub(CLVDebtRewardPerUnitStaked.mul(totalStakes));

            L_ETH = L_ETH.add(ETHRewardPerUnitStaked);
            L_CLVDebt = L_CLVDebt.add(CLVDebtRewardPerUnitStaked);
        }
        // Transfer coll and debt from ActivePool to DefaultPool
        poolManager.liquidate(_debt, _coll);
    }

    function closeCDP(address _user) external onlyBorrowerOperations {
        return _closeCDP(_user);
    }

    function _closeCDP(address _user) internal {
        CDPs[_user].status = Status.closed;
        CDPs[_user].coll = 0;
        CDPs[_user].debt = 0;
        
        rewardSnapshots[_user].ETH = 0;
        rewardSnapshots[_user].CLVDebt = 0;
 
        _removeCDPOwner(_user);
        sortedCDPs.remove(_user);
    }

    // Update the snapshots of system stakes & system collateral
    function _updateSystemSnapshots() internal {
        totalStakesSnapshot = totalStakes;

        /* The total collateral snapshot is the sum of all active collateral and all pending rewards
       (ActivePool ETH + DefaultPool ETH), immediately after the liquidation occurs. */
        uint activeColl = activePool.getETH();
        uint liquidatedColl = defaultPool.getETH();
        totalCollateralSnapshot = activeColl.add(liquidatedColl);
    }

    // Updates snapshots of system stakes and system collateral, excluding a given collateral remainder from the calculation
    function _updateSystemSnapshots_excludeCollRemainder(uint _collRemainder) internal {
        totalStakesSnapshot = totalStakes;

        uint activeColl = activePool.getETH();
        uint liquidatedColl = defaultPool.getETH();
        totalCollateralSnapshot = activeColl.sub(_collRemainder).add(liquidatedColl);
    }
  
    // Push the owner's address to the CDP owners list, and record the corresponding array index on the CDP struct
    function addCDPOwnerToArray(address _user) external onlyBorrowerOperations returns (uint index) {
        return _addCDPOwnerToArray(_user);
    }

    function _addCDPOwnerToArray(address _user) internal returns (uint128 index) {
        require(CDPOwners.length < 2**128 - 1, "CDPManager: CDPOwners array has maximum size of 2^128 - 1");
        
        // Push the user to the array, and convert the returned length to index of the new element, as a uint128
        index = uint128(CDPOwners.push(_user).sub(1));
        CDPs[_user].arrayIndex = index;

        return index;
    }

     /* Remove a CDP owner from the CDPOwners array, not preserving order. Removing owner 'B' does the following: 
    [A B C D E] => [A E C D], and updates E's CDP struct to point to its new array index. */
    function _removeCDPOwner(address _user) internal {
        require(CDPs[_user].status == Status.closed, "CDPManager: CDP is still active");

        uint128 index = CDPs[_user].arrayIndex;   
        uint length = CDPOwners.length;
        uint idxLast = length.sub(1);

        assert(length >= 1);  // Encapsulating function should only be reachable when there are > 0 troves in the system
        assert(index <= idxLast); 

        address addressToMove = CDPOwners[idxLast];
       
        CDPOwners[index] = addressToMove;   
        CDPs[addressToMove].arrayIndex = index;   
        CDPOwners.length--;  
    }
  
    // --- Recovery Mode and TCR functions ---

    function checkRecoveryMode() external view returns (bool) {
        return _checkRecoveryMode();
    }

    // Check whether or not the system *would be* in Recovery Mode, given an ETH:USD price and the total system coll and debt.
    function _checkPotentialRecoveryMode(uint _entireSystemColl, uint _entireSystemDebt, uint _price) internal pure returns (bool) {
        uint TCR = Math._computeCR(_entireSystemColl, _entireSystemDebt, _price); 
        if (TCR < CCR) {
            return true;
        } else {
            return false;
        }
    }

    function getTCR() external view returns (uint TCR) {
        uint price = priceFeed.getPrice();
        return _getTCR(price);
    }

    function _checkRecoveryMode() internal view returns (bool) {
        uint price = priceFeed.getPrice();
        uint TCR = _getTCR(price);
        
        if (TCR < CCR) {
            return true;
        } else {
            return false;
        }
    }
    
    function _getTCR(uint _price) internal view returns (uint TCR) { 
        uint activeColl = activePool.getETH();
        uint activeDebt = activePool.getCLVDebt();
        uint liquidatedColl = defaultPool.getETH();
        uint closedDebt = defaultPool.getCLVDebt();

        uint totalCollateral = activeColl.add(liquidatedColl);
        uint totalDebt = activeDebt.add(closedDebt); 

        TCR = Math._computeCR(totalCollateral, totalDebt, _price); 

        return TCR;
    }

    // --- 'require' wrapper functions ---

    function _requireCDPisActive(address _user) internal view {
        require(CDPs[_user].status == Status.active, "CDPManager: Trove does not exist or is closed");
    }

    function _requireCLVBalanceCoversRedemption(address _user, uint _amount) internal view {
        require(clvToken.balanceOf(_user) >= _amount, "CDPManager: Requested redemption amount must be >= user's CLV token balance");
    }

    function _requireETHSentSuccessfully(bool _success) internal pure {
        require(_success, "CDPManager: Failed to send ETH to msg.sender");
    }

    // --- Trove property getters ---

    function getCDPStatus(address _user) external view returns (uint) {
        return uint(CDPs[_user].status);
    }

    function getCDPStake(address _user) external view returns (uint) {
        return CDPs[_user].stake;
    }

    function getCDPDebt(address _user) external view returns (uint) {
        return CDPs[_user].debt;
    }

    function getCDPColl(address _user) external view returns (uint) {
        return CDPs[_user].coll;
    }

    // --- Trove property setters --- 

    function setCDPStatus(address _user, uint _num) external onlyBorrowerOperations {
        CDPs[_user].status = Status(_num);
    }

    function increaseCDPColl(address _user, uint _collIncrease) external onlyBorrowerOperations returns (uint) {
        uint newColl = CDPs[_user].coll.add(_collIncrease);
        CDPs[_user].coll = newColl;
        return newColl;
    }

    function decreaseCDPColl(address _user, uint _collDecrease) external onlyBorrowerOperations returns (uint) {
        uint newColl = CDPs[_user].coll.sub(_collDecrease);
        CDPs[_user].coll = newColl;
        return newColl;
    }

    function increaseCDPDebt(address _user, uint _debtIncrease) external onlyBorrowerOperations returns (uint) {
        uint newDebt = CDPs[_user].debt.add(_debtIncrease);
        CDPs[_user].debt = newDebt;
        return newDebt;
    }

    function decreaseCDPDebt(address _user, uint _debtDecrease) external onlyBorrowerOperations returns (uint) {
        uint newDebt = CDPs[_user].debt.sub(_debtDecrease);
        CDPs[_user].debt = newDebt;
        return newDebt;
    }

    function () external payable  {
        require(msg.data.length == 0);
    }
}