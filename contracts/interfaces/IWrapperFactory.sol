pragma solidity >=0.4.24;

contract IWrapperFactory {
    function createWrapper(address _erc20, bytes32 _synthName) external returns (address);
}
