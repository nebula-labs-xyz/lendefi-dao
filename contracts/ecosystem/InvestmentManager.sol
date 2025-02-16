// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * @title Lendefi DAO Ecosystem Investment manager
 * @notice Handles privaste placements and vesting contracts
 * @author Nebula Labs LLC
 * @custom:security-contact security@nebula-labs.xyz
 */

import {ILENDEFI} from "../interfaces/ILendefi.sol";
import {IWETH9} from "../interfaces/IWETH9.sol";
import {IINVESTOR} from "../interfaces/IInvestmentManager.sol";
import {InvestorVesting} from "./InvestorVesting.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20, SafeERC20 as TH} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

/// @custom:oz-upgrades
contract InvestmentManager is
    IINVESTOR,
    Initializable,
    PausableUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    /// @dev AccessControl Pauser Role
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    /// @dev AccessControl Manager Role
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    /// @dev AccessControl Upgrader Role
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    /// @dev AccessControl Allocator Role
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");

    /// @dev governance token instance
    ILENDEFI internal ecosystemToken;
    /// @dev WETH token instance
    IWETH9 internal wethContract;
    /// @dev timelock address
    address public timelock;
    /// @dev treasury address
    address public treasury;
    /// @dev amount of ecosystem tokens in the contract
    uint256 public supply;
    /// @dev amount of tokens allocated to vesting
    uint256 public totalAllocation;
    /// @dev number of UUPS upgrades
    uint32 public version;
    /// @dev number of the current round
    uint32 public round;
    /// @dev Round object array
    Round[] public rounds;
    /// @dev Investor to round mapping
    mapping(uint32 round_ => address[] participans) internal investors_;
    /// @dev tracks investor position in the investors_ array mapping above
    /// @dev in order to be able to cancel investments without looping, just like EnumarableSet contract
    mapping(uint32 round_ => mapping(address src => uint256 pos)) internal ipos;
    /// @dev Vesting contract addresses for investors per round
    mapping(uint32 round_ => mapping(address src => address vesting)) internal vestingContracts;
    /// @dev Tracks investor allocations per round
    mapping(uint32 round_ => mapping(address src => Investment)) internal investorAllocations;
    /// @dev Allocation to round mapping
    mapping(uint32 round_ => uint256 allocated) internal totalRoundAllocations;
    uint256[50] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice solidity receive function
    /// @dev triggers the investEther function on receive
    receive() external payable {
        if (msg.sender != address(wethContract)) investEther(round);
    }

    /**
     * @dev Initializes the this contract
     * @param token ecosystem token address
     * @param timelock_ timelock address
     * @param treasury_ treasury address
     * @param weth_ WETH address
     * @param guardian guardian address
     */
    function initialize(address token, address timelock_, address treasury_, address weth_, address guardian)
        external
        initializer
    {
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        if (
            token != address(0x0) && timelock_ != address(0x0) && treasury_ != address(0x0) && weth_ != address(0x0)
                && guardian != address(0x0)
        ) {
            _grantRole(DEFAULT_ADMIN_ROLE, guardian);
            _grantRole(MANAGER_ROLE, timelock_);
            _grantRole(PAUSER_ROLE, guardian);
            _grantRole(ALLOCATOR_ROLE, guardian);
            ecosystemToken = ILENDEFI(payable(token));
            wethContract = IWETH9(payable(weth_));

            timelock = timelock_;
            treasury = treasury_;
            version++;
            emit Initialized(msg.sender);
        } else {
            revert CustomError("ZERO_ADDRESS_DETECTED");
        }
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
     * @dev Creates an investment round.
     * @param start round start timestamp
     * @param duration seconds
     * @param ethTarget round target amount in ETH
     * @param tokenAlloc number of ecosystem tokens allocated to the round
     */
    function createRound(uint64 start, uint64 duration, uint256 ethTarget, uint256 tokenAlloc)
        external
        onlyRole(MANAGER_ROLE)
    {
        // Validate parameters
        if (duration < 5 days) revert CustomError("INVALID_DURATION");
        if (ethTarget == 0) revert CustomError("INVALID_ETH_ALLOCATION");
        if (tokenAlloc == 0) revert CustomError("INVALID_TOKEN_ALLOCATION");
        if (start < uint64(block.timestamp - 1 days)) revert CustomError("INVALID_START_TIME");

        // Check token supply
        supply += tokenAlloc;
        uint256 balance = ecosystemToken.balanceOf(address(this));
        if (balance < supply) revert CustomError("NO_SUPPLY");

        // Calculate end time
        uint64 end = start + uint64(duration);

        // Create new round with initial status 0 (Not Started)
        Round memory item = Round(ethTarget, 0, tokenAlloc, 0, start, end, 0);

        rounds.push(item);

        // Initialize round allocation tracking
        uint32 roundId = SafeCast.toUint32(rounds.length - 1);
        totalRoundAllocations[roundId] = 0;

        emit CreateRound(SafeCast.toUint32(rounds.length - 1), start, duration, ethTarget, tokenAlloc);
    }
    /**
     * @dev Green list investors and allocation post KYC.
     * @param round_ round number in question
     * @param src investor address
     * @param amountETH amount of ETH to invest
     * @param amountToken token allocation
     */

    function addInvestorAllocation(uint32 round_, address src, uint256 amountETH, uint256 amountToken)
        external
        onlyRole(ALLOCATOR_ROLE)
    {
        if (round_ >= rounds.length) revert CustomError("INVALID_ROUND");
        if (src == address(0)) revert CustomError("INVALID_ADDRESS");
        if (amountETH == 0) revert CustomError("INVALID_ETH_AMOUNT");
        if (amountToken == 0) revert CustomError("INVALID_TOKEN_AMOUNT");
        Round storage currentRound = rounds[round_];
        Investment storage investment = investorAllocations[round_][src];
        uint256 totalAllocated = totalRoundAllocations[round_] + amountToken;

        // Check if the new allocation exceeds the total allocation for the round
        if (totalAllocated > currentRound.tokenAllocation) {
            revert CustomError("ALLOCATION_EXCEEDS_ROUND_LIMIT");
        }

        investment.etherAmount += amountETH;
        investment.tokenAmount += amountToken;
        totalRoundAllocations[round_] = totalAllocated;
    }

    /**
     * @dev Green list investors and allocation post KYC.
     * @param round_ round number in question
     * @param src investor address
     */
    function removeInvestorAllocation(uint32 round_, address src) external onlyRole(ALLOCATOR_ROLE) {
        if (round_ >= rounds.length) revert CustomError("INVALID_ROUND");
        delete investorAllocations[round_][src];
    }

    /**
     * @dev Processes WETH investment into a round.
     * @param round_ round number in question
     * @param amount amount of ETH to invest
     */
    function investWETH(uint32 round_, uint256 amount) external whenNotPaused {
        if (round_ >= rounds.length) revert CustomError("INVALID_ROUND");
        invest(round_, amount);
        TH.safeTransferFrom(IERC20(address(wethContract)), msg.sender, address(this), amount);
    }

    /**
     * @dev Allows investor to get a rufund from an open round.
     * @param round_ round number in question
     */
    function cancelInvestment(uint32 round_) external nonReentrant {
        if (round_ >= rounds.length) revert CustomError("INVALID_ROUND");
        Round storage current = rounds[round_];
        if (current.etherInvested == current.etherTarget) {
            revert CustomError("ROUND_CLOSED");
        }

        uint256 pos = ipos[round_][msg.sender];
        if (pos == 0) revert CustomError("INVESTOR_NOT_EXIST");

        investors_[round_][pos - 1] = investors_[round_][investors_[round_].length - 1];
        investors_[round_].pop();
        ipos[round_][msg.sender] = 0;

        Investment memory item = investorAllocations[round_][msg.sender];
        investorAllocations[round_][msg.sender] = Investment(0, 0);

        totalAllocation -= item.tokenAmount;
        current.etherInvested -= item.etherAmount;
        current.participants--;
        emit CancelInvestment(round_, msg.sender, item.etherAmount);
        TH.safeTransfer(IERC20(address(wethContract)), msg.sender, item.etherAmount);
    }

    /**
     * @dev Closes an investment round after the round target has been reached.
     * @param round_ round number in question
     */
    function closeRound(uint32 round_) external nonReentrant {
        if (round_ >= rounds.length) revert CustomError("INVALID_ROUND");
        Round memory current = rounds[round_];

        if (current.etherInvested < current.etherTarget) {
            revert CustomError("ROUND_STILL_OPEN");
        }

        round++;
        deployVestingContracts(round_);
        wethContract.withdraw(current.etherInvested);

        emit RoundClosed(msg.sender, round_);
        (bool success,) = payable(treasury).call{value: current.etherInvested}("");
        if (!success) revert CustomError("WITHDRAWAL_FAILED");
    }

    /**
     * @dev Allows manager to cancel a round if need be, and issues refunds (WETH) to investors.
     * @param round_ round number in question
     */
    function cancelRound(uint32 round_) external nonReentrant onlyRole(MANAGER_ROLE) {
        if (round_ >= rounds.length) revert CustomError("INVALID_ROUND");
        Round memory current = rounds[round_];
        if (current.etherInvested == current.etherTarget) {
            revert CustomError("ROUND_CLOSED");
        }

        address[] memory investors = investors_[round_];
        uint64 len = SafeCast.toUint64(investors.length);
        if (round_ != rounds.length - 1 || round_ == 0) {
            revert CustomError("CANT_CANCEL_ROUND");
        }

        rounds.pop();
        supply -= current.tokenAllocation;
        emit RoundCancelled(round_);
        uint256 total = totalAllocation;
        if (len <= 50) {
            for (uint64 i; i < len; ++i) {
                Investment memory item = investorAllocations[round_][investors[i]];
                total = total - item.tokenAmount;
                investorAllocations[round_][investors[i]] = Investment(0, 0);
                TH.safeTransfer(IERC20(address(wethContract)), investors[i], item.etherAmount);
            }
            totalAllocation = total;
            withdrawTokens(round_, current.tokenAllocation);
        } else {
            revert CustomError("GAS_LIMIT");
        }
    }

    /**
     * @dev Getter ruturns the curretly active round.
     * @return current round number
     */
    function getCurrentRound() external view returns (uint32) {
        return round;
    }

    /**
     * @dev Getter ruturns the curretly active round details: Round object.
     * @param round_ round number in question
     * @return returns Round object
     */
    function getRoundInfo(uint32 round_) external view returns (IINVESTOR.Round memory) {
        return rounds[round_];
    }

    /**
     * @dev Getter ruturns investor allocation info.
     * @param round_ round number in question
     * @param src investor address
     * @return returns Investment object
     */
    function getInvestorAllocation(uint32 round_, address src) external view returns (IINVESTOR.Investment memory) {
        return investorAllocations[round_][src];
    }

    /**
     * @dev Getter ruturns the round's min invest amount.
     * @param round_ round number in question
     * @return returns min invest amount (ETH)
     */
    function getMinInvestAmount(uint32 round_) external view returns (uint256) {
        IINVESTOR.Round memory item = rounds[round_];
        return item.etherTarget / 50;
    }

    /**
     * @dev Processes ETH investment into a round.
     * @param round_ round number in question
     */
    function investEther(uint32 round_) public payable whenNotPaused {
        if (round_ >= rounds.length) revert CustomError("INVALID_ROUND");
        invest(round_, msg.value);
        Address.sendValue(payable(address(wethContract)), msg.value);
    }

    /**
     * @dev internal invest logic.
     * @param round_ round number in question
     * @param amount amount of ETH to invest
     */
    function invest(uint32 round_, uint256 amount) internal {
        Round storage item = rounds[round_];
        Investment storage investment = investorAllocations[round_][msg.sender];
        if (investment.etherAmount != amount) {
            revert CustomError("INVALID_AMOUNT");
        }

        if (item.etherInvested + amount > item.etherTarget) {
            revert CustomError("ROUND_OVERSUBSCRIBED");
        }

        uint256 pos = ipos[round_][msg.sender];
        if (pos == 0) {
            investors_[round_].push(msg.sender);
            ipos[round_][msg.sender] = investors_[round_].length;
        }

        item.participants = investors_[round_].length;
        item.etherInvested += amount;
        totalAllocation += investment.tokenAmount;

        emit Invest(round_, msg.sender, amount);
        if (item.etherInvested == item.etherTarget) emit RoundComplete(round_);
    }

    /**
     * @dev internal, deploys vesting contracts while closing the round.
     * @param round_ round number in question
     */
    function deployVestingContracts(uint32 round_) internal {
        address[] memory investors = investors_[round_];
        uint256 len = investors.length;
        address[] memory temp;
        investors_[round_] = temp;
        if (len <= 50) {
            for (uint256 i; i < len; ++i) {
                uint256 alloc = investorAllocations[round][investors[i]].tokenAmount;
                InvestorVesting vestingContract = new InvestorVesting(
                    address(ecosystemToken),
                    investors[i],
                    SafeCast.toUint64(block.timestamp + 365 days), // cliff timestamp
                    SafeCast.toUint64(730 days) // duration after cliff
                );
                emit DeployVesting(round_, investors[i], address(vestingContract), alloc);
                vestingContracts[round][investors[i]] = address(vestingContract);
                TH.safeTransfer(ecosystemToken, address(vestingContract), alloc);
            }
        } else {
            revert CustomError("GAS_LIMIT");
        }
    }

    /**
     * @dev internal, withdraws tokens back to treasury when the round is cancelled.
     * @param amount amount of tokens to send back to treasury
     */
    function withdrawTokens(uint32 round_, uint256 amount) internal {
        emit WithdrawTokens(round_, msg.sender, amount);
        TH.safeTransfer(ecosystemToken, treasury, amount);
    }

    /// @inheritdoc UUPSUpgradeable
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {
        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }
}
