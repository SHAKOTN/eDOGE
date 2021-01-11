// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../Dependencies/SafeMath.sol";
import "../Dependencies/Ownable.sol";
import "../Dependencies/console.sol";
import "../Interfaces/ILQTYToken.sol";
import "../Interfaces/ILQTYStaking.sol";
import "../Dependencies/LiquityMath.sol";
import "../Interfaces/ILUSDToken.sol";

contract LQTYStaking is ILQTYStaking, Ownable {
    using SafeMath for uint;

    // --- Data ---

    mapping( address => uint) public stakes;
    uint public totalLQTYStaked;

    uint public F_LUSD; // Running sum of LUSD fees per-LQTY-staked

    // User snapshots of F_LUSD, taken at the point at which their latest deposit was made
    mapping (address => Snapshot) public snapshots; 

    struct Snapshot {
        uint F_LUSD_Snapshot;
    }
    
    ILQTYToken public lqtyToken;
    ILUSDToken public lusdToken;

    address public troveManagerAddress;
    address public borrowerOperationsAddress;
    address public activePoolAddress;

    // --- Events ---

    event LQTYTokenAddressSet(address _lqtyTokenAddress);
    event LUSDTokenAddressSet(address _lusdTokenAddress);
    event TroveManagerAddressSet(address _troveManager);
    event BorrowerOperationsAddressSet(address _borrowerOperationsAddress);
    event ActivePoolAddressSet(address _activePoolAddress);

    event StakeChanged(address indexed _staker, uint _newStake);
    event StakingGainsWithdrawn(address indexed _staker, uint _LUSDGain);

    // --- Functions ---

    function setAddresses
    (
        address _lqtyTokenAddress,
        address _lusdTokenAddress,
        address _troveManagerAddress, 
        address _borrowerOperationsAddress,
        address _activePoolAddress
    ) 
        external 
        onlyOwner 
        override 
    {
        lqtyToken = ILQTYToken(_lqtyTokenAddress);
        lusdToken = ILUSDToken(_lusdTokenAddress);
        troveManagerAddress = _troveManagerAddress;
        borrowerOperationsAddress = _borrowerOperationsAddress;
        activePoolAddress = _activePoolAddress;

        emit LQTYTokenAddressSet(_lqtyTokenAddress);
        emit LQTYTokenAddressSet(_lusdTokenAddress);
        emit TroveManagerAddressSet(_troveManagerAddress);
        emit BorrowerOperationsAddressSet(_borrowerOperationsAddress);
        emit ActivePoolAddressSet(_activePoolAddress);

        _renounceOwnership();
    }

    // If caller has a pre-existing stake, send any accumulated LUSD gains to them. 
    function stake(uint _LQTYamount) external override {
        uint currentStake = stakes[msg.sender];

        uint LUSDGain;
        // Grab any accumulated LUSD gains from the current stake
        if (currentStake != 0) {
            LUSDGain = getPendingLUSDGain(msg.sender);
        }
    
       _updateUserSnapshot(msg.sender);

        uint newStake = currentStake.add(_LQTYamount);

        // Increase user’s stake and total LQTY staked
        stakes[msg.sender] = newStake;
        totalLQTYStaked = totalLQTYStaked.add(_LQTYamount);

        // Transfer LQTY from caller to this contract
        lqtyToken.sendToLQTYStaking(msg.sender, _LQTYamount);

        emit StakeChanged(msg.sender, newStake);
        emit StakingGainsWithdrawn(msg.sender, LUSDGain);

        // Send accumulated LUSD gains to the caller
        lusdToken.transfer(msg.sender, LUSDGain);
    }

    // Unstake the LQTY and send the it back to the caller, along with their accumulated LUSD gains. 
    // If requested amount > stake, send their entire stake.
    function unstake(uint _LQTYamount) external override {
        uint currentStake = stakes[msg.sender];
        _requireUserHasStake(currentStake);

        // Grab any accumulated LUSD gain from the current stake
        uint LUSDGain = getPendingLUSDGain(msg.sender);
        
        _updateUserSnapshot(msg.sender);

        uint LQTYToWithdraw = LiquityMath._min(_LQTYamount, currentStake);

        uint newStake = currentStake.sub(LQTYToWithdraw);

        // Decrease user's stake and total LQTY staked
        stakes[msg.sender] = newStake;
        totalLQTYStaked = totalLQTYStaked.sub(LQTYToWithdraw);  

        // Transfer unstaked LQTY to user
        lqtyToken.transfer(msg.sender, LQTYToWithdraw);

        emit StakeChanged(msg.sender, newStake);
        emit StakingGainsWithdrawn(msg.sender, LUSDGain);

        // Send accumulated LUSD gain to the caller
        lusdToken.transfer(msg.sender, LUSDGain);
    }

    // --- Reward-per-unit-staked increase function. Called by Liquity core contracts ---

    function increaseF_LUSD(uint _LUSDFee) external override {
        _requireCallerIsBorrowerOperations();
        uint LUSDFeePerLQTYStaked;
        
        if (totalLQTYStaked > 0) {LUSDFeePerLQTYStaked = _LUSDFee.mul(1e18).div(totalLQTYStaked);}
        
        F_LUSD = F_LUSD.add(LUSDFeePerLQTYStaked);
    }

    // --- Pending reward functions ---

    function getPendingLUSDGain(address _user) public view override returns (uint) {
        uint F_LUSD_Snapshot = snapshots[_user].F_LUSD_Snapshot;
        uint LUSDGain = stakes[_user].mul(F_LUSD.sub(F_LUSD_Snapshot)).div(1e18);
        return LUSDGain;
    }

    // --- Internal helper functions ---

    function _updateUserSnapshot(address _user) internal {
        snapshots[_user].F_LUSD_Snapshot = F_LUSD;
    }

    // --- 'require' functions ---

    function _requireCallerIsTroveManager() internal view {
        require(msg.sender == troveManagerAddress, "LQTYStaking: caller is not TroveM");
    }

    function _requireCallerIsBorrowerOperations() internal view {
        require(msg.sender == borrowerOperationsAddress, "LQTYStaking: caller is not BorrowerOps");
    }

    function _requireCallerIsActivePool() internal view {
        require(msg.sender == activePoolAddress, "LQTYStaking: caller is not ActivePool");
    }

    function _requireUserHasStake(uint currentStake) internal pure {  
        require(currentStake > 0, 'LQTYStaking: User must have a non-zero stake');  
    }
}
