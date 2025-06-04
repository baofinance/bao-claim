// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title BaoIDO
 * @notice Merkle-gated IDO contract for allocating shares using USDC.
 * Discounted shares are prioritized in allocation. Oversubscriptions are allowed;
 * excess full-price share purchases will be refunded manually via the multisig.
 */
contract BaoIDO is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                     ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    error SaleNotStarted();
    error SaleEnded();
    error InvalidProof();
    error ZeroDeposit();
    error InvalidToken();
    error NothingToSweep();
    error InvalidDates();
    error InvalidAddress();
    error InvalidPrices();
    error InvalidAmount();

    /*//////////////////////////////////////////////////////////////////////////
                                  STRUCTURES
    //////////////////////////////////////////////////////////////////////////*/

    struct PurchaseInfo {
        uint256 totalPurchased;
        uint256 discountedPurchased;
        uint256 fullPricePurchased;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 public merkleRoot;
    IERC20 public usdc;
    address public multisig;

    uint256 public start;
    uint256 public end;
    uint256 public discountPrice;  // USDC (6 decimals)
    uint256 public fullPrice;      // USDC (6 decimals)

    uint256 public immutable maxShares = 6_000_000;
    uint256 public immutable maxDiscounted = 6_000_000;

    /*//////////////////////////////////////////////////////////////////////////
                                   STATE
    //////////////////////////////////////////////////////////////////////////*/

    mapping(address => PurchaseInfo) public purchases;
    uint256 public totalSharesSold;
    uint256 public totalDiscountedSold;

    /*//////////////////////////////////////////////////////////////////////////
                                   EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event Purchased(address indexed buyer, uint256 discounted, uint256 full, uint256 usdcSpent);
    event MerkleConfigUpdated(bytes32 merkleRoot, uint256 discountPrice, uint256 fullPrice);
    event PriceConfigUpdated(bytes32 merkleRoot, uint256 discountPrice, uint256 fullPrice);
    event DatesUpdated(uint256 start, uint256 end);
    event MultisigUpdated(address newMultisig);
    event Swept(address indexed token, uint256 amount, address indexed to);

    /*//////////////////////////////////////////////////////////////////////////
                                 CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /**
    * @notice Initializes the IDO contract
    * @param _usdc Address of USDC token
    * @param _multisig Address that will receive funds (and initial owner)
    * @param _merkleRoot Root of the Merkle tree for verification
    * @param _start Sale start timestamp
    * @param _end Sale end timestamp
    * @param _discountPrice Price per discounted share (6 decimals)
    * @param _fullPrice Price per full-price share (6 decimals)
    */
    constructor(
        address _usdc,
        address _multisig,
        bytes32 _merkleRoot,
        uint256 _start,
        uint256 _end,
        uint256 _discountPrice,
        uint256 _fullPrice
    ) Ownable(_multisig) {
        if (_start >= _end) revert InvalidDates();
        usdc = IERC20(_usdc);
        multisig = _multisig;
        merkleRoot = _merkleRoot;
        start = _start;
        end = _end;
        discountPrice = _discountPrice;
        fullPrice = _fullPrice;
    }

    /*//////////////////////////////////////////////////////////////////////////
                               PURCHASE FUNCTION
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Purchase IDO shares. All purchases go through. Discounted shares are prioritized.
     * @param discountedShares Number of shares being claimed at discount
     * @param totalShares Total number of shares requested (discounted + full)
     * @param userMaxDiscounted The maximum discounted allocation (from Merkle tree)
     * @param proof Merkle proof of eligibility
     * @dev Oversubscribed purchases will be refunded manually by multisig
     */
    function purchase(
        uint256 discountedShares,
        uint256 totalShares,
        uint256 userMaxDiscounted,
        bytes32[] calldata proof
    ) external nonReentrant {
        uint256 current = block.timestamp;
        uint256 _start = start;
        uint256 _end = end;

        if (current < _start) revert SaleNotStarted();
        if (current > _end) revert SaleEnded();
        if (totalShares == 0) revert ZeroDeposit();

        // Verify Merkle eligibility
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, userMaxDiscounted));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();

        if (discountedShares > totalShares) revert InvalidAmount();
        
        // Calculate actual discounted allocation
        uint256 discounted = min(discountedShares, userMaxDiscounted);
        uint256 full = totalShares - discounted;

        uint256 cost = (discounted * discountPrice) + (full * fullPrice);

        // Overflow check
        if (totalSharesSold + totalShares > type(uint256).max) revert InvalidAmount();
        
        // Update state
        PurchaseInfo storage info = purchases[msg.sender];
        info.totalPurchased += totalShares;
        info.discountedPurchased += discounted;
        info.fullPricePurchased += full;

        uint256 newTotal = totalSharesSold + totalShares;
        uint256 newDiscounted = totalDiscountedSold + discounted;
        totalSharesSold = newTotal;
        totalDiscountedSold = newDiscounted;

        usdc.safeTransferFrom(msg.sender, multisig, cost);
        emit Purchased(msg.sender, discounted, full, cost);
    }

    /*//////////////////////////////////////////////////////////////////////////
                               ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /**
    * @notice Updates the Merkle root used for verifying eligibility
    * @param _root The new Merkle root hash
    */
    function setMerkleRoot(bytes32 _root) external onlyOwner {
        merkleRoot = _root;
        emit MerkleConfigUpdated(_root, discountPrice, fullPrice);
    }

    /**
    * @notice Updates the share prices for both discounted and full-price purchases
    * @param _discountPrice New price per discounted share (6 decimals)
    * @param _fullPrice New price per full-price share (6 decimals)
    */
    function setPrices(uint256 _discountPrice, uint256 _fullPrice) external onlyOwner {
        if (_discountPrice == 0 || _fullPrice == 0) revert InvalidAmount();
        if (_discountPrice >= _fullPrice) revert InvalidPrices();
        discountPrice = _discountPrice;
        fullPrice = _fullPrice;
        emit PriceConfigUpdated(merkleRoot, _discountPrice, _fullPrice);
    }

    /**
     * @notice Updates the start and end date for the claim window.
     * @param _start New start timestamp.
     * @param _end New end timestamp.
     */
    function setDates(uint256 _start, uint256 _end) external onlyOwner {
        if (_start >= _end) revert InvalidDates();
        start = _start;
        end = _end;
        emit DatesUpdated(_start, _end);
    }

    /**
     * @notice Updates the multisig address that receives unclaimed tokens.
     * @param _multisig New multisig address.
     */
    function setMultisig(address _multisig) external onlyOwner {
        if (_multisig == address(0)) revert InvalidAddress();
        multisig = _multisig;
        emit MultisigUpdated(_multisig);
    }

    /**
     * @notice Sweep any ERC20 tokens sent by mistake to the contract.
     * @param _token Address of the token to sweep.
     */
    function sweep(address _token) external onlyOwner {
        if (_token == address(0)) revert InvalidToken();

        uint256 balance = IERC20(_token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        IERC20(_token).safeTransfer(multisig, balance);
        emit Swept(_token, balance, multisig);
    }

    /*//////////////////////////////////////////////////////////////////////////
                             PUBLIC HELPER VIEWS
    //////////////////////////////////////////////////////////////////////////*/

    /**
    * @notice Checks if the IDO sale is currently active
    * @return bool True if current time is within sale window
    */    
    function isSaleActive() external view returns (bool) {
        return block.timestamp >= start && block.timestamp <= end;
    }

    /**
    * @notice Checks if total shares sold exceeds maximum allocation
    * @return bool True if oversubscribed
    */
    function isOverSubscribed() external view returns (bool) {
        return totalSharesSold > maxShares;
    }

    /**
    * @notice Calculates total cost for given shares
    * @param discountedShares Number of discounted shares
    * @param fullShares Number of full-price shares
    * @return uint256 Total cost in USDC (6 decimals)
    */
    function getCost(uint256 discountedShares, uint256 fullShares) public view returns (uint256) {
        return (discountedShares * discountPrice) + (fullShares * fullPrice);
    }

    /**
    * @notice Returns the number of shares remaining for purchase
    * @return uint256 Remaining shares available in the IDO
    */
    function remainingShares() external view returns (uint256) {
        return maxShares - totalSharesSold;
    }

    /**
    * @notice Returns the number of discounted shares remaining
    * @return uint256 Remaining discounted shares available
    */
    function remainingDiscountedShares() external view returns (uint256) {
        return maxDiscounted - totalDiscountedSold;
    }

    /*//////////////////////////////////////////////////////////////////////////
                             MATH HELPER
    //////////////////////////////////////////////////////////////////////////*/
    
    /**
    * @notice Returns the smaller of two numbers
    * @param a First number to compare
    * @param b Second number to compare
    * @return uint256 The smaller value
    */
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
