pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./interfaces/IAddressResolver.sol";
import "./interfaces/IERC20Wrapper.sol";
import "./interfaces/ISynth.sol";
import "./interfaces/IERC20.sol";

// Internal references
import "./Pausable.sol";
import "./interfaces/IIssuer.sol";
import "./interfaces/IExchangeRates.sol";
import "./interfaces/IFeePool.sol";
import "./MixinResolver.sol";
import "./MixinSystemSettings.sol";

// Libraries
import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";
import "./SafeDecimalMath.sol";

contract Erc20Wrapper is Owned, Pausable, MixinResolver, MixinSystemSettings, IERC20Wrapper {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    /* ========== CONSTANTS ============== */

    /* ========== ENCODED NAMES ========== */
    bytes32 internal constant sUSD = "sUSD";

    /* ========== ADDRESS RESOLVER CONFIGURATION ========== */
    bytes32 private constant CONTRACT_SYNTHSUSD = "SynthsUSD";
    bytes32 private constant CONTRACT_ISSUER = "Issuer";
    bytes32 private constant CONTRACT_EXRATES = "ExchangeRates";
    bytes32 private constant CONTRACT_FEEPOOL = "FeePool";

    // ========== STATE VARIABLES ==========
    IERC20 internal _erc20;
    bytes32 internal _synth_name;

    uint public synthsIssued = 0;
    uint public sUSDIssued = 0;
    uint public feesEscrowed = 0;

    constructor(
        address _owner,
        address _resolver,
        address _ERC20,
        bytes32 _SYNTH_NAME
    ) public Owned(_owner) Pausable() MixinSystemSettings(_resolver) {
        _erc20 = IERC20(_ERC20);
        _synth_name = _SYNTH_NAME;
    }

    /* ========== VIEWS ========== */
    function resolverAddressesRequired() public view returns (bytes32[] memory addresses) {
        bytes32[] memory existingAddresses = MixinSystemSettings.resolverAddressesRequired();
        bytes32[] memory newAddresses = new bytes32[](5);
        newAddresses[0] = _synth_name;
        newAddresses[1] = CONTRACT_SYNTHSUSD;
        newAddresses[2] = CONTRACT_EXRATES;
        newAddresses[3] = CONTRACT_ISSUER;
        newAddresses[4] = CONTRACT_FEEPOOL;
        addresses = combineArrays(existingAddresses, newAddresses);
        return addresses;
    }

    /* ========== INTERNAL VIEWS ========== */
    function synthsUSD() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(CONTRACT_SYNTHSUSD));
    }

    function synthERC20() internal view returns (ISynth) {
        return ISynth(requireAndGetAddress(_synth_name));
    }

    function feePool() internal view returns (IFeePool) {
        return IFeePool(requireAndGetAddress(CONTRACT_FEEPOOL));
    }

    function exchangeRates() internal view returns (IExchangeRates) {
        return IExchangeRates(requireAndGetAddress(CONTRACT_EXRATES));
    }

    function issuer() internal view returns (IIssuer) {
        return IIssuer(requireAndGetAddress(CONTRACT_ISSUER));
    }

    /* ========== PUBLIC FUNCTIONS ========== */

    // ========== VIEWS ==========

    function capacity() public view returns (uint _capacity) {
        // capacity = max(maxERC20 - balance, 0)
        uint balance = getReserves();
        if (balance >= maxERC20()) {
            return 0;
        }
        return maxERC20().sub(balance);
    }

    function getReserves() public view returns (uint) {
        return _erc20.balanceOf(address(this));
    }

    function totalIssuedSynths() public view returns (uint) {
        // This contract issues two different synths:
        // 1. The synth corresponding to the ERC20
        // 2. sUSD
        //
        // The synth is always backed 1:1 with the corresponding ERC20.
        // The sUSD fees are backed by the synth that is withheld during minting and burning.
        return exchangeRates().effectiveValue(_synth_name, synthsIssued, sUSD).add(sUSDIssued);
    }

    function calculateMintFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(mintFeeRate());
    }

    function calculateBurnFee(uint amount) public view returns (uint) {
        return amount.multiplyDecimalRound(burnFeeRate());
    }

    function maxERC20() public view returns (uint256) {
        return getERC20WrapperMaxTokens(_synth_name);
    }

    function mintFeeRate() public view returns (uint256) {
        return getERC20WrapperMintFeeRate(_synth_name);
    }

    function burnFeeRate() public view returns (uint256) {
        return getERC20WrapperBurnFeeRate(_synth_name);
    }

    function erc20() public view returns (IERC20) {
        return _erc20;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // Transfers `amountIn` of the ERC20 to mint `amountIn - fees` of the synth.
    // `amountIn` is inclusive of fees, calculable via `calculateMintFee`.
    function mint(uint amountIn) external notPaused {
        require(amountIn <= _erc20.allowance(msg.sender, address(this)), "Allowance not high enough");
        require(amountIn <= _erc20.balanceOf(msg.sender), "Balance is too low");

        uint currentCapacity = capacity();
        require(currentCapacity > 0, "Contract has no spare capacity to mint");

        if (amountIn < currentCapacity) {
            _mint(amountIn);
        } else {
            _mint(currentCapacity);
        }
    }

    // Burns `amountIn` of the synth for `amountIn - fees` of the ERC20.
    // `amountIn` is inclusive of fees, calculable via `calculateBurnFee`.
    function burn(uint amountIn) external notPaused {
        uint reserves = getReserves();
        require(reserves > 0, "Contract cannot burn synths for the ERC20 token, the ERC20 token balance is zero");

        // principal = [amountIn / (1 + burnFeeRate)]
        uint principal = amountIn.divideDecimalRound(SafeDecimalMath.unit().add(burnFeeRate()));

        if (principal < reserves) {
            _burn(principal, amountIn);
        } else {
            _burn(reserves, reserves.add(calculateBurnFee(reserves)));
        }
    }

    function distributeFees() external {
        // Normalize fee to sUSD
        require(!exchangeRates().rateIsInvalid(_synth_name), "Currency rate is invalid");
        uint amountSUSD = exchangeRates().effectiveValue(_synth_name, feesEscrowed, sUSD);

        // Burn the synth.
        synthERC20().burn(address(this), feesEscrowed);
        // Pay down as much _synth_name debt as we burn. Any other debt is taken on by the stakers.
        synthsIssued = synthsIssued < feesEscrowed ? 0 : synthsIssued.sub(feesEscrowed);

        // Issue sUSD to the fee pool
        issuer().synths(sUSD).issue(feePool().FEE_ADDRESS(), amountSUSD);
        sUSDIssued = sUSDIssued.add(amountSUSD);

        // Tell the fee pool about this
        feePool().recordFeePaid(amountSUSD);

        feesEscrowed = 0;
    }

    // ========== RESTRICTED ==========

    /**
     * @notice Fallback function
     */
    function() external payable {
        revert("Fallback disabled, use mint()");
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function _mint(uint amountIn) internal {
        // Calculate minting fee.
        uint feeAmountInSynth = calculateMintFee(amountIn);
        uint principal = amountIn.sub(feeAmountInSynth);

        // Transfer _erc20 from user.
        _erc20.transferFrom(msg.sender, address(this), amountIn);

        // Mint `amountIn - fees` synth to user.
        synthERC20().issue(msg.sender, principal);

        // Escrow fee.
        synthERC20().issue(address(this), feeAmountInSynth);
        feesEscrowed = feesEscrowed.add(feeAmountInSynth);

        // Add synth debt.
        synthsIssued = synthsIssued.add(amountIn);

        emit Minted(msg.sender, principal, feeAmountInSynth, amountIn);
    }

    function _burn(uint principal, uint amountIn) internal {
        // for burn, amount is inclusive of the fee.
        uint feeAmountInSynth = amountIn.sub(principal);

        require(amountIn <= IERC20(address(synthERC20())).allowance(msg.sender, address(this)), "Allowance not high enough");
        require(amountIn <= IERC20(address(synthERC20())).balanceOf(msg.sender), "Balance is too low");

        // Burn `amountIn` synth from user.
        synthERC20().burn(msg.sender, amountIn);
        // Synth debt is repaid by burning.
        synthsIssued = synthsIssued < principal ? 0 : synthsIssued.sub(principal);

        // We use burn/issue instead of burning the principal and transferring the fee.
        // This saves an approval and is cheaper.
        // Escrow fee.
        synthERC20().issue(address(this), feeAmountInSynth);
        // We don't update synthsIssued, as only the principal was subtracted earlier.
        feesEscrowed = feesEscrowed.add(feeAmountInSynth);

        // Transfer `amount - fees` _erc20 to user.
        _erc20.transfer(msg.sender, principal);

        emit Burned(msg.sender, principal, feeAmountInSynth, amountIn);
    }

    /* ========== EVENTS ========== */
    event Minted(address indexed account, uint principal, uint fee, uint amountIn);
    event Burned(address indexed account, uint principal, uint fee, uint amountIn);
}
