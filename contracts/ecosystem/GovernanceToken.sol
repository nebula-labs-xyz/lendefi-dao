// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO GovernanceToken
 * @notice Burnable contract that votes and has BnM-Bridge functionality
 * @dev Implements a secure and upgradeable DAO governance token
 * @custom:security-contact security@nebula-labs.xyz
 */

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20BurnableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PausableUpgradeable.sol";
import {ERC20VotesUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {
    ERC20PermitUpgradeable,
    NoncesUpgradeable
} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";

/// @custom:oz-upgrades
contract GovernanceToken is
    ERC20Upgradeable,
    ERC20BurnableUpgradeable,
    ERC20PausableUpgradeable,
    AccessControlUpgradeable,
    ERC20PermitUpgradeable,
    ERC20VotesUpgradeable,
    UUPSUpgradeable
{
    // ============ Constants ============

    /// @notice Token supply and distribution constants
    uint256 private constant INITIAL_SUPPLY = 50_000_000 ether;
    uint256 private constant MAX_BRIDGE_AMOUNT = 20_000 ether;
    uint256 private constant TREASURY_SHARE = 56;
    uint256 private constant ECOSYSTEM_SHARE = 44;

    /// @dev AccessControl Pauser Role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev AccessControl Bridge Role
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    /// @dev AccessControl Upgrader Role
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    // ============ Storage Variables ============

    /// @dev Initial token supply
    uint256 public initialSupply;
    /// @dev max bridge passthrough amount
    uint256 public maxBridge;
    /// @dev number of UUPS upgrades
    uint32 public version;
    /// @dev tge initialized variable
    uint32 public tge;
    uint256[50] private __gap;

    // ============ Events ============

    /**
     * @dev Initialized Event.
     * @param src sender address
     */
    event Initialized(address indexed src);

    /// @dev event emitted at TGE
    /// @param amount token amount
    event TGE(uint256 amount);

    /**
     * @dev event emitted when bridge triggers a mint
     * @param src sender
     * @param to beneficiary address
     * @param amount token amount
     */
    event BridgeMint(address indexed src, address indexed to, uint256 amount);

    /// @dev event emitted on UUPS upgrades
    /// @param src sender address
    /// @param implementation new implementation address
    event Upgrade(address indexed src, address indexed implementation);

    /// @dev CustomError message
    /// @param msg error description message
    error CustomError(string msg);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the UUPS contract.
     * @notice Sets up the initial state of the contract, including roles and token supplies.
     * @param guardian The address of the guardian (admin).
     * @custom:requires The guardian address must not be zero.
     * @custom:events-emits {Initialized} event.
     * @custom:throws CustomError("ZERO_ADDRESS") if the guardian address is zero.
     */
    function initializeUUPS(address guardian) external initializer {
        __ERC20_init("Lendefi DAO", "LEND");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __ERC20Permit_init("Lendefi Coin");
        __ERC20Votes_init();
        __UUPSUpgradeable_init();

        require(guardian != address(0x0), "ZERO_ADDRESS");
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(PAUSER_ROLE, guardian);
        initialSupply = INITIAL_SUPPLY;
        maxBridge = MAX_BRIDGE_AMOUNT;
        version++;
        emit Initialized(msg.sender);
    }

    /**
     * @dev Initializes the Token Generation Event (TGE).
     * @notice Sets up the initial token distribution between the ecosystem and treasury contracts.
     * @param ecosystem The address of the ecosystem contract.
     * @param treasury The address of the treasury contract.
     * @custom:requires The ecosystem and treasury addresses must not be zero.
     * @custom:requires TGE must not be already initialized.
     * @custom:events-emits {TGE} event.
     * @custom:throws CustomError("ZERO_ADDRESS") if any of the addresses are zero.
     * @custom:throws CustomError("TGE_ALREADY_INITIALIZED") if TGE is already initialized.
     */
    function initializeTGE(address ecosystem, address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ecosystem == address(0x0) || treasury == address(0x0)) revert CustomError({msg: "ZERO_ADDRESS"});
        if (tge > 0) revert CustomError({msg: "TGE_ALREADY_INITIALIZED"});
        ++tge;

        emit TGE(initialSupply);
        _mint(address(this), initialSupply);

        uint256 maxTreasury = (initialSupply * TREASURY_SHARE) / 100;
        uint256 maxEcosystem = (initialSupply * ECOSYSTEM_SHARE) / 100;

        _transfer(address(this), treasury, maxTreasury);
        _transfer(address(this), ecosystem, maxEcosystem);
    }

    /**
     * @dev Pauses all token transfers and operations.
     * @notice This function can be called by an account with the PAUSER_ROLE to pause the contract.
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Paused} event from PausableUpgradeable
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers and operations.
     * @notice This function can be called by an account with the PAUSER_ROLE to unpause the contract.
     * @custom:requires-role PAUSER_ROLE
     * @custom:events-emits {Unpaused} event from PausableUpgradeable
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Facilitates Bridge BnM functionality called by the bridge app.
     * @notice Mints new tokens to a specified address, called by an account with the BRIDGE_ROLE.
     * @param to The address that will receive the minted tokens.
     * @param amount The amount of tokens to mint.
     * @custom:requires-role BRIDGE_ROLE
     * @custom:requires Amount must not exceed maxBridge.
     * @custom:requires Total supply must not exceed initialSupply.
     * @custom:events-emits {BridgeMint} event
     * @custom:throws CustomError("BRIDGE_LIMIT") if the amount exceeds maxBridge.
     * @custom:throws CustomError("BRIDGE_PROBLEM") if the total supply exceeds initialSupply.
     */
    function bridgeMint(address to, uint256 amount) external onlyRole(BRIDGE_ROLE) {
        if (amount > maxBridge) revert CustomError({msg: "BRIDGE_LIMIT"});
        if (amount + totalSupply() > initialSupply) {
            revert CustomError({msg: "BRIDGE_PROBLEM"});
        }

        emit BridgeMint(msg.sender, to, amount);
        _mint(to, amount);
    }

    // The following functions are overrides required by Solidity.
    /// @inheritdoc ERC20PermitUpgradeable
    function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
        return super.nonces(owner);
    }

    /// @inheritdoc ERC20Upgradeable
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20Upgradeable, ERC20PausableUpgradeable, ERC20VotesUpgradeable)
    {
        super._update(from, to, value);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
