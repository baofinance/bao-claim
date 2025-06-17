// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ZhengLongIDO
 * @notice Merkle-gated IDO contract that allows eligible users to deposit USDC.
 * @dev Tracks total deposits, unique depositors, and individual allocations.
 * All deposited funds are immediately forwarded to the multisig wallet.
 * Allocation breakdown is handled off-chain at TGE.
 */
contract ZhengLongIDO is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                     ERRORS
    //////////////////////////////////////////////////////////////////////////*/
    error SaleNotStarted();
    error SaleEnded();
    error ZeroDeposit();
    error InvalidProof();
    error InvalidAddress();
    error NothingToSweep();

    /*//////////////////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////////////////*/
    event Deposited(address indexed user, uint256 amount, uint256 totalUserDeposits);
    event DatesUpdated(uint256 start, uint256 end);
    event MerkleRootUpdated(bytes32 newRoot);
    event MultisigUpdated(address newMultisig);
    event Swept(address indexed token, uint256 amount, address indexed to);

    /*//////////////////////////////////////////////////////////////////////////
                                   CONFIG
    //////////////////////////////////////////////////////////////////////////*/
    IERC20 public immutable usdc; // Gas optimization: make immutable
    address public multisig;
    bytes32 public merkleRoot;

    uint256 public start;
    uint256 public end;

    /*//////////////////////////////////////////////////////////////////////////
                                DEPOSIT TRACKING
    //////////////////////////////////////////////////////////////////////////*/
    uint256 public totalDeposited;
    uint256 public totalDepositors; // Tracks unique addresses that deposited
    mapping(address => uint256) public userDeposits;

    /*//////////////////////////////////////////////////////////////////////////
                                   CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/
    constructor(
        address _usdc,
        address _multisig,
        bytes32 _merkleRoot,
        uint256 _start,
        uint256 _end
    ) Ownable(_multisig) {
        require(_usdc != address(0) && _multisig != address(0), "Invalid address");
        require(_start < _end, "Invalid sale window");

        usdc = IERC20(_usdc);
        multisig = _multisig;
        merkleRoot = _merkleRoot;
        start = _start;
        end = _end;
    }

    /*//////////////////////////////////////////////////////////////////////////
                               DEPOSIT FUNCTION
    //////////////////////////////////////////////////////////////////////////*/
    /**
     * @notice Deposit USDC if the user is included in the Merkle tree
     * @dev Funds are immediately forwarded to the multisig wallet
     * @param amount Amount of USDC to deposit (6 decimals)
     * @param proof Merkle proof verifying the user is eligible
     */
    function deposit(uint256 amount, bytes32[] calldata proof) external nonReentrant {
        if (block.timestamp < start) revert SaleNotStarted();
        if (block.timestamp > end) revert SaleEnded();
        if (amount == 0) revert ZeroDeposit();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        // Track if this is a new depositor
        bool isNewDepositor = userDeposits[msg.sender] == 0;
        
        usdc.safeTransferFrom(msg.sender, multisig, amount);

        totalDeposited += amount;
        userDeposits[msg.sender] += amount;
        
        if (isNewDepositor) {
            totalDepositors++;
        }

        emit Deposited(msg.sender, amount, userDeposits[msg.sender]);
    }

    /*//////////////////////////////////////////////////////////////////////////
                               ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    function setMerkleRoot(bytes32 _root) external onlyOwner {
        merkleRoot = _root;
        emit MerkleRootUpdated(_root);
    }

    function setDates(uint256 _start, uint256 _end) external onlyOwner {
        require(_start < _end, "Invalid dates");
        start = _start;
        end = _end;
        emit DatesUpdated(_start, _end);
    }

    function setMultisig(address _multisig) external onlyOwner {
        if (_multisig == address(0)) revert InvalidAddress();
        multisig = _multisig;
        emit MultisigUpdated(_multisig);
    }

    function sweep(address _token) external onlyOwner {
        if (_token == address(0)) revert InvalidAddress();
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();
        IERC20(_token).safeTransfer(multisig, balance);
        emit Swept(_token, balance, multisig);
    }

    /*//////////////////////////////////////////////////////////////////////////
                               VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/
    /**
     * @notice Check if sale is currently active
     */
    function isSaleActive() external view returns (bool) {
        return block.timestamp >= start && block.timestamp <= end;
    }

    /**
     * @notice Get user's total deposited amount
     * @param user Address to check
     * @return uint256 Amount deposited by user
     */
    function getUserDeposit(address user) external view returns (uint256) {
        return userDeposits[user];
    }

    /**
     * @notice Get total amount deposited in the IDO
     * @return uint256 Total USDC deposited
     */
    function getTotalDeposits() external view returns (uint256) {
        return totalDeposited;
    }

    /**
     * @notice Get count of unique depositors
     * @return uint256 Number of unique addresses that deposited
     */
    function getDepositorCount() external view returns (uint256) {
        return totalDepositors;
    }
}