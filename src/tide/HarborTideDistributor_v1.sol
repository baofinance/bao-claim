// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {HarborOwnableRoles} from "@bao/HarborOwnableRoles.sol";

import {IHarborTideDistributor} from "@tide/interfaces/IHarborTideDistributor.sol";
import {IHarborTideDistributorConfig} from "@tide/interfaces/IHarborTideDistributorConfig.sol";
import {IHarborTideDistributorErrors} from "@tide/interfaces/IHarborTideDistributorErrors.sol";
import {IVotingEscrow} from "@tide/interfaces/IVotingEscrow.sol";

/// @title HarborTideDistributor_v1
/// @notice One-shot, non-upgradeable TGE distributor for the TIDE token with three independent paths:
///         (1) `convertBao` swaps BAO -> TIDE at a fixed rate, (2) `claimVeBao` merkle-claims TIDE for eligible
///         veBAO positions, (3) `claimStandard` merkle-claims TIDE for a standard allocation. Paths 1+2 share a
///         250m TIDE cap; path 3 has a separate 30m TIDE cap. See `src/tide/README.md` for the full architecture,
///         conversion math, merkle leaf format, and threat model.
/// @dev Non-upgradeable: all economics are immutable/constant and set at deploy; only merkle roots and the
///      multisig may change, and only before `startDate`. The `_v1` suffix is a naming convention (harbor style),
///      not an upgradeable implementation slot. BAO is never held — it is forwarded to the multisig on each swap.
///      Standard ERC20 only (no fee-on-transfer / rebasing handling).
///      Acknowledged: path-1 swaps round TIDE down (`baoToTide`), so up to a sub-wei (<1 wei TIDE) of value per swap
///      is intentionally not credited (dust). This is accepted by design and is never refunded; the `MIN_TIDE_OUT`
///      floor keeps any such rounding immaterial relative to the swap size.
// solhint-disable-next-line contract-name-camelcase
contract HarborTideDistributor_v1 is
    IHarborTideDistributor,
    IHarborTideDistributorConfig,
    IHarborTideDistributorErrors,
    HarborOwnableRoles,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Role allowed to update merkle roots before `startDate` (owner also allowed).
    uint256 public constant CONFIG_ROLE = _ROLE_0;

    /// @notice Maximum BAO convertible via path 1 (1,422,000,000 BAO).
    uint256 public constant MAX_BAO = 1_422_000_000e18;

    /// @notice Shared TIDE cap for path 1 (swap) + path 2 (veBAO merkle) (250,000,000 TIDE).
    uint256 public constant MAX_TIDE_SWAP_AND_VE = 250_000_000e18;

    /// @notice Separate TIDE cap for path 3 (standard merkle) (30,000,000 TIDE).
    uint256 public constant MAX_TIDE_STANDARD = 30_000_000e18;

    /// @notice Minimum TIDE output required for a path-1 swap (10 TIDE; ~57 BAO at the fixed rate).
    /// @dev Anti-dust floor only; rounding loss is <=1 wei TIDE, so this is well above any rounding concern.
    uint256 public constant MIN_TIDE_OUT = 10e18;

    /// @notice Fixed conversion rate numerator: 1 BAO -> 0.1758 TIDE = `TIDE_NUMERATOR / RATE_DENOMINATOR`.
    uint256 public constant TIDE_NUMERATOR = 1758;

    /// @notice Fixed conversion rate denominator.
    uint256 public constant RATE_DENOMINATOR = 10_000;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The TIDE claim token (funded into this contract).
    IERC20 public immutable TIDE;

    /// @notice The BAO swap input token (path 1).
    IERC20 public immutable BAO;

    /// @notice The veBAO voting escrow read for path 2 eligibility.
    IVotingEscrow public immutable VEBAO;

    /// @notice Timestamp when all three paths open (inclusive).
    uint256 public immutable startDate;

    /// @notice Timestamp when all three paths close (exclusive).
    uint256 public immutable endDate;

    /// @notice Block number of the veBAO eligibility snapshot (expected 25,000,000 on mainnet).
    /// @dev Path-2 claims revert until `block.number >= SNAPSHOT_BLOCK` so `balanceOfAt` is well-defined.
    uint256 public immutable SNAPSHOT_BLOCK;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Recipient of swapped BAO and destination of post-window sweeps.
    address public multisig;

    /// @notice Path-2 veBAO merkle root (leaves: `(account, tideAmount)`).
    bytes32 public veBaoMerkleRoot;

    /// @notice Path-3 standard merkle root (leaves: `(account, tideAmount)`).
    bytes32 public standardMerkleRoot;

    /// @notice Total BAO converted via path 1 (hard-capped at `MAX_BAO`).
    uint256 public totalBaoConverted;

    /// @notice Total TIDE distributed via paths 1 + 2 (hard-capped at `MAX_TIDE_SWAP_AND_VE`).
    uint256 public totalTideSwapAndVe;

    /// @notice Total TIDE distributed via path 3 (hard-capped at `MAX_TIDE_STANDARD`).
    uint256 public totalTideStandard;

    /// @notice Whether an account has claimed on path 2.
    mapping(address => bool) public hasClaimedVeBao;

    /// @notice Whether an account has claimed on path 3.
    mapping(address => bool) public hasClaimedStandard;

    /// @notice Cumulative BAO converted by an account on path 1 (analytics).
    mapping(address => uint256) public baoConverted;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Restricts configuration to before the window opens; immutable thereafter.
    modifier beforeStart() {
        if (block.timestamp >= startDate) revert ConfigLocked();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param tide_ TIDE claim token address.
    /// @param bao_ BAO swap input token address.
    /// @param veBao_ veBAO voting escrow address.
    /// @param startDate_ Timestamp when the claim window opens.
    /// @param endDate_ Timestamp when the claim window closes.
    /// @param snapshotBlock_ veBAO eligibility snapshot block (25,000,000 on mainnet).
    /// @param multisig_ Owner, BAO recipient, and post-window sweep destination.
    /// @param veBaoMerkleRoot_ Initial path-2 veBAO merkle root.
    /// @param standardMerkleRoot_ Initial path-3 standard merkle root.
    constructor(
        address tide_,
        address bao_,
        address veBao_,
        uint256 startDate_,
        uint256 endDate_,
        uint256 snapshotBlock_,
        address multisig_,
        bytes32 veBaoMerkleRoot_,
        bytes32 standardMerkleRoot_
    ) {
        if (startDate_ >= endDate_) revert InvalidDates();
        if (tide_ == address(0) || bao_ == address(0) || veBao_ == address(0) || multisig_ == address(0)) {
            revert InvalidAddress();
        }

        _initializeOwner(multisig_, multisig_);

        TIDE = IERC20(tide_);
        BAO = IERC20(bao_);
        VEBAO = IVotingEscrow(veBao_);
        startDate = startDate_;
        endDate = endDate_;
        SNAPSHOT_BLOCK = snapshotBlock_;
        multisig = multisig_;
        veBaoMerkleRoot = veBaoMerkleRoot_;
        standardMerkleRoot = standardMerkleRoot_;
    }

    /*//////////////////////////////////////////////////////////////
                            PATH 1 — SWAP
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborTideDistributor
    function convertBao(uint256 baoAmount) external nonReentrant {
        if (block.timestamp < startDate) revert ClaimNotStarted();
        if (block.timestamp >= endDate) revert ClaimEnded();
        if (baoAmount == 0) revert InvalidAmount();

        // tideOut rounds down; any sub-wei remainder is acknowledged, uncredited dust (see baoToTide).
        uint256 tideOut = baoToTide(baoAmount);
        if (tideOut < MIN_TIDE_OUT) revert BelowMinSwap();
        if (totalBaoConverted + baoAmount > MAX_BAO) revert BaoCapExceeded();
        if (totalTideSwapAndVe + tideOut > MAX_TIDE_SWAP_AND_VE) revert TideSwapVeCapExceeded();
        if (TIDE.balanceOf(address(this)) < tideOut) revert InsufficientBalance();

        totalBaoConverted += baoAmount;
        totalTideSwapAndVe += tideOut;
        baoConverted[msg.sender] += baoAmount;

        // BAO is forwarded directly to the multisig in the same tx; never held by this contract.
        BAO.safeTransferFrom(msg.sender, multisig, baoAmount);
        TIDE.safeTransfer(msg.sender, tideOut);

        emit BaoConverted(msg.sender, baoAmount, tideOut);
    }

    /*//////////////////////////////////////////////////////////////
                            PATH 2 — veBAO
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborTideDistributor
    function claimVeBao(uint256 tideAmount, bytes32[] calldata proof) external nonReentrant {
        if (block.number < SNAPSHOT_BLOCK) revert SnapshotNotReached();
        if (block.timestamp < startDate) revert ClaimNotStarted();
        if (block.timestamp >= endDate) revert ClaimEnded();
        if (hasClaimedVeBao[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, tideAmount))));
        if (!MerkleProof.verify(proof, veBaoMerkleRoot, leaf)) revert InvalidProof();

        // Lock must extend strictly past the distributor window (still active at claim time).
        if (VEBAO.locked__end(msg.sender) <= endDate) revert LockEndTooEarly();

        // BAO-equivalent snapshot must cover the merkle allocation, and the live lock must still back it.
        uint256 snapshotBaoEquivalent = VEBAO.balanceOfAt(msg.sender, SNAPSHOT_BLOCK);
        if (snapshotBaoEquivalent < tideToBao(tideAmount)) revert InsufficientSnapshotBalance();
        if (_lockedAmount(msg.sender) < snapshotBaoEquivalent) revert LockBelowSnapshot();

        if (totalTideSwapAndVe + tideAmount > MAX_TIDE_SWAP_AND_VE) revert TideSwapVeCapExceeded();
        if (TIDE.balanceOf(address(this)) < tideAmount) revert InsufficientBalance();

        hasClaimedVeBao[msg.sender] = true;
        totalTideSwapAndVe += tideAmount;

        TIDE.safeTransfer(msg.sender, tideAmount);
        emit VeBaoClaimed(msg.sender, tideAmount);
    }

    /// @inheritdoc IHarborTideDistributor
    function getVeClaimStatus(address user, uint256 tideAmount) external view returns (VeClaimStatus memory status) {
        status.veEnd = VEBAO.locked__end(user);
        status.lockedAmount = _lockedAmount(user);
        status.snapshotBaoEquivalent = VEBAO.balanceOfAt(user, SNAPSHOT_BLOCK);
        status.snapshotRequired = tideToBao(tideAmount);
        status.minUnlockTime = endDate + 1;
        status.alreadyClaimed = hasClaimedVeBao[user];
        status.poolCapAvailable = totalTideSwapAndVe + tideAmount <= MAX_TIDE_SWAP_AND_VE;
        status.canClaimNow = block.number >= SNAPSHOT_BLOCK && !status.alreadyClaimed && block.timestamp >= startDate
            && block.timestamp < endDate && status.veEnd > endDate
            && status.snapshotBaoEquivalent >= status.snapshotRequired
            && status.lockedAmount >= status.snapshotBaoEquivalent && status.poolCapAvailable;
    }

    /*//////////////////////////////////////////////////////////////
                            PATH 3 — STANDARD
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborTideDistributor
    function claimStandard(uint256 tideAmount, bytes32[] calldata proof) external nonReentrant {
        if (block.timestamp < startDate) revert ClaimNotStarted();
        if (block.timestamp >= endDate) revert ClaimEnded();
        if (hasClaimedStandard[msg.sender]) revert AlreadyClaimed();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, tideAmount))));
        if (!MerkleProof.verify(proof, standardMerkleRoot, leaf)) revert InvalidProof();

        if (totalTideStandard + tideAmount > MAX_TIDE_STANDARD) revert TideStandardCapExceeded();
        if (TIDE.balanceOf(address(this)) < tideAmount) revert InsufficientBalance();

        hasClaimedStandard[msg.sender] = true;
        totalTideStandard += tideAmount;

        TIDE.safeTransfer(msg.sender, tideAmount);
        emit StandardClaimed(msg.sender, tideAmount);
    }

    /*//////////////////////////////////////////////////////////////
                            CONVERSION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborTideDistributor
    /// @dev Rounds TIDE DOWN. Any fractional remainder (< 1 wei TIDE) is acknowledged dust: it is not credited to the
    ///      swapper and not refunded. Rounding down (never up) ensures the contract can never over-distribute TIDE.
    function baoToTide(uint256 baoAmount) public pure returns (uint256) {
        return baoAmount * TIDE_NUMERATOR / RATE_DENOMINATOR;
    }

    /// @inheritdoc IHarborTideDistributor
    function tideToBao(uint256 tideAmount) public pure returns (uint256) {
        return (tideAmount * RATE_DENOMINATOR + TIDE_NUMERATOR - 1) / TIDE_NUMERATOR;
    }

    /*//////////////////////////////////////////////////////////////
                            CONFIG (BEFORE START)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborTideDistributorConfig
    function setVeBaoMerkleRoot(bytes32 root) external onlyOwnerOrRoles(CONFIG_ROLE) beforeStart {
        veBaoMerkleRoot = root;
        emit VeBaoMerkleRootUpdated(root);
    }

    /// @inheritdoc IHarborTideDistributorConfig
    function setStandardMerkleRoot(bytes32 root) external onlyOwnerOrRoles(CONFIG_ROLE) beforeStart {
        standardMerkleRoot = root;
        emit StandardMerkleRootUpdated(root);
    }

    /// @inheritdoc IHarborTideDistributorConfig
    function setMultisig(address multisig_) external onlyOwner beforeStart {
        if (multisig_ == address(0)) revert InvalidAddress();
        multisig = multisig_;
        emit MultisigUpdated(multisig_);
    }

    /*//////////////////////////////////////////////////////////////
                            SWEEP / RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IHarborTideDistributorConfig
    function sweep() external onlyOwner nonReentrant {
        if (block.timestamp <= endDate) revert ClaimNotOver();

        uint256 balance = TIDE.balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        TIDE.safeTransfer(multisig, balance);
        emit Sweep(multisig, balance);
    }

    /// @inheritdoc IHarborTideDistributorConfig
    function recoverySweep(address token) external onlyOwner {
        if (block.timestamp <= endDate) revert ClaimNotOver();
        if (token == address(TIDE) || token == address(BAO)) revert CannotRecoverClaimToken();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) revert NothingToSweep();

        IERC20(token).safeTransfer(multisig, balance);
        emit Recovered(token, balance);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC165 SUPPORT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc HarborOwnableRoles
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IHarborTideDistributor).interfaceId
            || interfaceId == type(IHarborTideDistributorConfig).interfaceId || super.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reads the current locked BAO for `user`, casting the veBAO `int128` to `uint256` (clamps negatives to 0).
    function _lockedAmount(address user) internal view returns (uint256) {
        int128 amount = VEBAO.locked(user).amount;
        // cast is safe: guarded by `amount > 0`, so the value fits in uint128 (and therefore uint256).
        // forge-lint: disable-next-line(unsafe-typecast)
        return amount > 0 ? uint256(uint128(amount)) : 0;
    }
}
