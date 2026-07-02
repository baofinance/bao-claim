// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";

/// @title BaoClaim
/// @notice Merkle-based claim contract that allows whitelisted users to claim tokens during a fixed period.
/// @dev Unclaimed tokens can be swept to a multisig after the claim window ends.
contract BaoClaim is HarborOwnableRoles, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role allowed to update claim configuration outside the active claim window.
    uint256 public constant CONFIG_ROLE = _ROLE_0;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error ClaimNotStarted();
    error ClaimEnded();
    error AlreadyClaimed();
    error InvalidProof();
    error InsufficientBalance();
    error ClaimNotOver();
    error NothingToSweep();
    error InvalidDates();
    error ClaimWindowActive();
    error CannotRecoverClaimToken();
    error InvalidAddress();
    error InvalidAmount();

    /*//////////////////////////////////////////////////////////////
                               STORAGE
    //////////////////////////////////////////////////////////////*/

    bytes32 public merkleRoot;
    IERC20 public immutable TOKEN;
    uint256 public startDate;
    uint256 public endDate;
    address public multisig;
    uint256 public claimAmount;
    mapping(address => bool) public hasClaimed;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event Claimed(address indexed claimer);
    event Sweep(address indexed to, uint256 amount);
    event ClaimAmountUpdated(uint256 newAmount);
    event Recovered(address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param merkleRoot_ Root of the Merkle tree with eligible addresses.
    /// @param startDate_ Timestamp when claiming starts.
    /// @param endDate_ Timestamp when claiming ends.
    /// @param multisig_ Owner and recipient of unclaimed tokens after the claim period.
    /// @param token_ Address of claimable token.
    /// @param claimAmount_ Claimable amount for each eligible address.
    constructor(
        bytes32 merkleRoot_,
        uint256 startDate_,
        uint256 endDate_,
        address multisig_,
        address token_,
        uint256 claimAmount_
    ) {
        if (startDate_ >= endDate_) revert InvalidDates();
        if (multisig_ == address(0) || token_ == address(0)) revert InvalidAddress();

        _initializeOwner(multisig_, multisig_);

        merkleRoot = merkleRoot_;
        TOKEN = IERC20(token_);
        startDate = startDate_;
        endDate = endDate_;
        multisig = multisig_;
        claimAmount = claimAmount_;
    }

    /*//////////////////////////////////////////////////////////////
                           CLAIM FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Allows eligible users to claim tokens using a valid Merkle proof.
    /// @param merkleProof Array of hashes that prove the sender is in the Merkle tree.
    function claim(bytes32[] calldata merkleProof) external nonReentrant {
        if (block.timestamp < startDate) revert ClaimNotStarted();
        if (block.timestamp >= endDate) revert ClaimEnded();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(merkleProof, merkleRoot, leaf)) revert InvalidProof();

        hasClaimed[msg.sender] = true;

        if (TOKEN.balanceOf(address(this)) < claimAmount) revert InsufficientBalance();

        TOKEN.safeTransfer(msg.sender, claimAmount);
        emit Claimed(msg.sender);
    }

    /// @notice Returns whether a user has claimed and the configured claim amount.
    function getClaimable(address user) external view returns (bool claimed, uint256 amount) {
        return (hasClaimed[user], claimAmount);
    }

    /*//////////////////////////////////////////////////////////////
                      SWEEP AND RECOVERY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sweeps unclaimed tokens to the multisig after the claim period ends.
    function sweep() external onlyOwner nonReentrant {
        uint256 end = endDate;
        if (block.timestamp <= end) revert ClaimNotOver();

        uint256 balance = TOKEN.balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        TOKEN.safeTransfer(multisig, balance);
        emit Sweep(multisig, balance);
    }

    /// @notice Recovers non-claim tokens accidentally sent to the contract after the claim window ends.
    /// @param token_ The address of the token to recover.
    function recoverySweep(address token_) external onlyOwner {
        uint256 end = endDate;
        if (block.timestamp <= end) revert ClaimNotOver();

        if (token_ == address(TOKEN)) revert CannotRecoverClaimToken();

        uint256 balance = IERC20(token_).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        IERC20(token_).safeTransfer(multisig, balance);
        emit Recovered(token_, balance);
    }

    /*//////////////////////////////////////////////////////////////
                           ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets a new Merkle root.
    /// @param root New Merkle root hash.
    function setMerkleRoot(bytes32 root) external onlyOwnerOrRoles(CONFIG_ROLE) {
        if (block.timestamp >= startDate && block.timestamp < endDate) {
            revert ClaimWindowActive();
        }
        merkleRoot = root;
    }

    /// @notice Updates the claimable amount.
    /// @param claimAmount_ New claim amount.
    function setClaimAmount(uint256 claimAmount_) external onlyOwnerOrRoles(CONFIG_ROLE) {
        if (claimAmount_ == 0) revert InvalidAmount();
        if (block.timestamp >= startDate && block.timestamp < endDate) {
            revert ClaimWindowActive();
        }
        claimAmount = claimAmount_;
        emit ClaimAmountUpdated(claimAmount_);
    }

    /// @notice Updates the start and end date for the claim window.
    /// @param startDate_ New start timestamp.
    /// @param endDate_ New end timestamp.
    function setDates(uint256 startDate_, uint256 endDate_) external onlyOwnerOrRoles(CONFIG_ROLE) {
        if (startDate_ >= endDate_) revert InvalidDates();
        if (block.timestamp >= startDate && block.timestamp < endDate) {
            revert ClaimWindowActive();
        }
        startDate = startDate_;
        endDate = endDate_;
    }

    /// @notice Updates the multisig address that receives unclaimed tokens.
    /// @param multisig_ New multisig address.
    function setMultisig(address multisig_) external onlyOwner {
        if (multisig_ == address(0)) revert InvalidAddress();
        multisig = multisig_;
    }

    /*//////////////////////////////////////////////////////////////
                           ERC165 SUPPORT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc HarborOwnableRoles
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
