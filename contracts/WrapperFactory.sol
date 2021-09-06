pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./interfaces/IWrapperFactory.sol";

// Internal references
import "./Pausable.sol";
import "./Erc20Wrapper.sol";

contract WrapperFactory is Owned, Pausable, IWrapperFactory {
    /* ========== CONSTANTS ============== */

    /* ========== ENCODED NAMES ========== */

    // ========== STATE VARIABLES ==========
    mapping(bytes32 => Erc20Wrapper) public erc20Wrappers;
    address private _resolver;

    constructor(address _owner, address _RESOLVER) public Owned(_owner) Pausable() {
        _resolver = _RESOLVER;
    }

    function createWrapper(address _erc20, bytes32 _synthName) external onlyOwner returns (address) {
        Erc20Wrapper synthWrapper = new Erc20Wrapper(owner, _resolver, _erc20, _synthName);
        erc20Wrappers[_synthName] = synthWrapper;
        return address(erc20Wrappers[_synthName]);
    }
}
