// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title BaoClaim
 * @notice A Merkle-based claim contract that allows whitelisted users to claim tokens during a fixed period.
 * Unclaimed tokens can be swept to a multisig after the claim window ends.
 */
contract BaoClaim is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                     ERRORS
    //////////////////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////////////////
                                   STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public merkleRoot;
    IERC20 public immutable token;
    uint256 public startDate;
    uint256 public endDate;
    address public multisig;
    uint256 public claimAmount;
    mapping(address => bool) public hasClaimed;

    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event Claimed(address indexed claimer);
    event Sweep(address indexed to, uint256 amount);
    event ClaimAmountUpdated(uint256 newAmount);
    event Recovered(address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Initializes the BaoClaim contract.
     * @param _merkleRoot Root of the Merkle tree with eligible addresses.
     * @param _startDate Timestamp when claiming starts.
     * @param _endDate Timestamp when claiming ends.
     * @param _multisig Address to receive unclaimed tokens after the claim period.
     * @param _token Address of claimable token.
     * @param _claimAmount Claimable amount for each eligible address.
     */
    constructor(bytes32 _merkleRoot, uint256 _startDate, uint256 _endDate, address _multisig, address _token, uint256 _claimAmount)
        Ownable(_multisig)
    {
        if (_startDate >= _endDate) revert InvalidDates();
        merkleRoot = _merkleRoot;
        token = IERC20(_token);
        startDate = _startDate;
        endDate = _endDate;
        multisig = _multisig;
        claimAmount = _claimAmount;
    }

    /*//////////////////////////////////////////////////////////////////////////
                               CLAIM FUNCTION
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows eligible users to claim tokens using a valid Merkle proof.
     * @param merkleProof Array of hashes that prove the sender is in the Merkle tree.
     */
    function claim(bytes32[] calldata merkleProof) external nonReentrant {
        if (block.timestamp < startDate) revert ClaimNotStarted();
        if (block.timestamp >= endDate) revert ClaimEnded();
        if (hasClaimed[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        bool valid = MerkleProof.verify(merkleProof, merkleRoot, leaf);
        if (!valid) revert InvalidProof();

        hasClaimed[msg.sender] = true;

        if (token.balanceOf(address(this)) < claimAmount) revert InsufficientBalance();

        token.safeTransfer(msg.sender, claimAmount);
        emit Claimed(msg.sender);
    }

    function getClaimable(address user) external view returns (bool claimed, uint256 amount) {
    return (hasClaimed[user], claimAmount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                              SWEEP AND RECOVERY FUNCTION
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Allows the owner to sweep unclaimed tokens to the multisig after the claim period ends.
     */
    function sweep() external onlyOwner nonReentrant {
        uint256 end = endDate;
        if (block.timestamp <= end) revert ClaimNotOver();

        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        token.safeTransfer(multisig, balance);
        emit Sweep(multisig, balance);
    }

    /**
    * @notice Allows the owner to recover non-claim tokens accidentally sent to the contract,
    * but only after the claim window has ended.
    * @param _token The address of the token to recover.
    */
    function recoverySweep(address _token) external onlyOwner {
        uint256 end = endDate;
        if (block.timestamp <= end) revert ClaimNotOver();

        if (_token == address(token)) revert CannotRecoverClaimToken();
        
        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();
        
        IERC20(_token).safeTransfer(multisig, balance);
        emit Recovered(_token, balance);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            ADMIN CONFIGURATION
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Sets a new Merkle root.
     * @param _newRoot New Merkle root hash.
     */
    function setMerkleRoot(bytes32 _newRoot) external onlyOwner {
        if (block.timestamp >= startDate && block.timestamp <= endDate) {
            revert ClaimWindowActive();
        }
        merkleRoot = _newRoot;
    }

    /**
    * @notice Updates the claimable amount.
    * @param _claimAmount New claim amount.
    */
    function setClaimAmount(uint256 _claimAmount) external onlyOwner {
        if (_claimAmount == 0) revert InvalidAmount();
        if (block.timestamp >= startDate && block.timestamp <= endDate) {
            revert ClaimWindowActive();
        }
        claimAmount = _claimAmount;
        emit ClaimAmountUpdated(_claimAmount);
    }

    /**
     * @notice Updates the start and end date for the claim window.
     * @param _startDate New start timestamp.
     * @param _endDate New end timestamp.
     */
    function setDates(uint256 _startDate, uint256 _endDate) external onlyOwner {
        if (_startDate >= _endDate) revert InvalidDates();
        if (block.timestamp >= startDate && block.timestamp <= endDate) {
            revert ClaimWindowActive();
        }
        startDate = _startDate;
        endDate = _endDate;
    }

    /**
     * @notice Updates the multisig address that receives unclaimed tokens.
     * @param _multisig New multisig address.
     */
    function setMultisig(address _multisig) external onlyOwner {
        if (_multisig == address(0)) revert InvalidAddress();
        multisig = _multisig;
    }
}
