// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ZhengLongIDO
/// @notice Merkle-gated IDO contract that allows eligible users to deposit USDC during a fixed sale window.
/// @dev Tracks total deposits, unique depositors, and per-user allocations. Deposited funds are forwarded
///      immediately to the multisig wallet. Allocation breakdown is handled off-chain at TGE.
// solhint-disable-next-line contract-name-camelcase
contract ZhengLongIDO is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error SaleNotStarted();
    error SaleEnded();
    error ZeroDeposit();
    error InvalidProof();
    error InvalidAddress();
    error InvalidDates();
    error NothingToSweep();

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable USDC;
    address public multisig;
    bytes32 public merkleRoot;
    uint256 public startDate;
    uint256 public endDate;
    uint256 public totalDeposited;
    uint256 public totalDepositors;
    mapping(address => uint256) public userDeposits;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposited(address indexed user, uint256 amount, uint256 totalUserDeposits);
    event DatesUpdated(uint256 startDate, uint256 endDate);
    event MerkleRootUpdated(bytes32 newRoot);
    event MultisigUpdated(address newMultisig);
    event Swept(address indexed token, uint256 amount, address indexed to);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param usdc_ USDC token address.
    /// @param multisig_ Owner and recipient of deposited USDC.
    /// @param merkleRoot_ Root of the Merkle tree with eligible addresses.
    /// @param startDate_ Timestamp when deposits open.
    /// @param endDate_ Timestamp when deposits close.
    constructor(address usdc_, address multisig_, bytes32 merkleRoot_, uint256 startDate_, uint256 endDate_)
        Ownable(multisig_)
    {
        if (usdc_ == address(0) || multisig_ == address(0)) revert InvalidAddress();
        if (startDate_ >= endDate_) revert InvalidDates();

        USDC = IERC20(usdc_);
        multisig = multisig_;
        merkleRoot = merkleRoot_;
        startDate = startDate_;
        endDate = endDate_;
    }

    /*//////////////////////////////////////////////////////////////
                           DEPOSIT FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit USDC if the caller is included in the Merkle tree.
    /// @dev Funds are immediately forwarded to the multisig wallet.
    /// @param amount Amount of USDC to deposit (6 decimals).
    /// @param proof Merkle proof verifying the caller is eligible.
    function deposit(uint256 amount, bytes32[] calldata proof) external nonReentrant {
        if (block.timestamp < startDate) revert SaleNotStarted();
        if (block.timestamp >= endDate) revert SaleEnded();
        if (amount == 0) revert ZeroDeposit();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        bool isNewDepositor = userDeposits[msg.sender] == 0;

        USDC.safeTransferFrom(msg.sender, multisig, amount);

        totalDeposited += amount;
        userDeposits[msg.sender] += amount;

        if (isNewDepositor) {
            totalDepositors++;
        }

        emit Deposited(msg.sender, amount, userDeposits[msg.sender]);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets a new Merkle root.
    /// @param root New Merkle root hash.
    function setMerkleRoot(bytes32 root) external onlyOwner {
        merkleRoot = root;
        emit MerkleRootUpdated(root);
    }

    /// @notice Updates the deposit window.
    /// @param startDate_ New start timestamp.
    /// @param endDate_ New end timestamp.
    function setDates(uint256 startDate_, uint256 endDate_) external onlyOwner {
        if (startDate_ >= endDate_) revert InvalidDates();
        startDate = startDate_;
        endDate = endDate_;
        emit DatesUpdated(startDate_, endDate_);
    }

    /// @notice Updates the multisig address that receives deposits.
    /// @param multisig_ New multisig address.
    function setMultisig(address multisig_) external onlyOwner {
        if (multisig_ == address(0)) revert InvalidAddress();
        multisig = multisig_;
        emit MultisigUpdated(multisig_);
    }

    /// @notice Sweeps stray ERC20 tokens sent to this contract to the multisig.
    /// @param token Token address to sweep.
    function sweep(address token) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();
        IERC20(token).safeTransfer(multisig, balance);
        emit Swept(token, balance, multisig);
    }

    /*//////////////////////////////////////////////////////////////
                           VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether the sale window is currently open.
    function isSaleActive() external view returns (bool) {
        return block.timestamp >= startDate && block.timestamp < endDate;
    }
}
