import './ICDPManager.sol';

// Proxy contract - used for calculating gas of read-only functions in gas calculation scripts.  Not part of the application.

contract FunctionCaller {

    ICDPManager cdpManager;
    address cdpManagerAddress;

    function setCDPManagerAddress(address _cdpManagerAddress) public {
        cdpManagerAddress = _cdpManagerAddress;
        cdpManager = ICDPManager(_cdpManagerAddress);
    }

    function cdpManager_getCurrentICR (address _address) public returns(uint) {
        cdpManager.getCurrentICR(_address);  
    }
}