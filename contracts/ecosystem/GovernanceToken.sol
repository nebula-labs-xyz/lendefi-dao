// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Governance Token
 * @notice Burnable contract that votes and has BnM-Bridge functionality, UUPSUpgradeable,
 * @author Nebula Labs LLC
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
    /// @dev AccessControl Pauser Role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev AccessControl Bridge Role
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    /// @dev AccessControl Upgrader Role
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @dev Initial token supply
    uint256 public initialSupply;
    /// @dev max bridge passthrough amount
    uint256 public maxBridge;
    /// @dev number of UUPS upgrades
    uint32 public version;
    /// @dev tge initialized variable
    uint32 public tge;
    uint256[50] private __gap;

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
     * @param src, sender
     * @param to beneficiary address
     * @param amount token amount
     */
    event BridgeMint(address indexed src, address indexed to, uint256 amount);

    /// @dev event emitted on UUPS upgrades
    /// @param src sender address
    /// @param implementation new implementation address
    event Upgrade(address indexed src, address indexed implementation);

    /// @dev CustomError message
    /// @param msg error desciption message
    error CustomError(string msg);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the UUPS contract
     * @param guardian admin address
     */
    function initializeUUPS(address guardian) external initializer {
        __ERC20_init("Lendefi Coin", "LENDEFI");
        __ERC20Burnable_init();
        __ERC20Pausable_init();
        __AccessControl_init();
        __ERC20Permit_init("Lendefi Coin");
        __ERC20Votes_init();
        __UUPSUpgradeable_init();

        require(guardian != address(0x0), "ZERO_ADDRESS");
        _grantRole(DEFAULT_ADMIN_ROLE, guardian);
        _grantRole(PAUSER_ROLE, guardian);
        initialSupply = 50_000_000 ether;
        maxBridge = 10_000 ether;
        version++;
        emit Initialized(msg.sender);
    }

    /**
     * @dev Initializes TGE
     * @param ecosystem ecosystem contract address
     * @param treasury treasury contract address
     */
    function initializeTGE(address ecosystem, address treasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (ecosystem == address(0x0) || treasury == address(0x0)) revert CustomError({msg: "ZERO_ADDRESS"});
        if (tge > 0) revert CustomError({msg: "TGE_ALREADY_INITIALIZED"});
        ++tge;

        emit TGE(initialSupply);
        _mint(address(this), initialSupply);

        uint256 maxTreasury = (initialSupply * 56) / 100;
        uint256 maxEcosystem = (initialSupply * 44) / 100;

        _transfer(address(this), treasury, maxTreasury);
        _transfer(address(this), ecosystem, maxEcosystem);
    }

    /**
     * @dev Pause contract.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause contract.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @dev Facilitates Bridge BnM functionality called by the bridge app.
     * @param to beneficiary address
     * @param amount token amount
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
