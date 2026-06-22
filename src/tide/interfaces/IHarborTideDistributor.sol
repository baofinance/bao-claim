// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IHarborTideDistributor
/// @notice User-facing API for {HarborTideDistributor_v1}: the three independent TIDE distribution paths
///         plus read helpers for integrators, frontends, and indexers.
/// @dev Path 1 (`convertBao`) swaps BAO -> TIDE at a fixed rate. Path 2 (`claimVeBao`) and path 3
///      (`claimStandard`) are merkle claims whose leaves encode `(account, tideAmount)` in TIDE.
interface IHarborTideDistributor {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on a path-1 BAO -> TIDE swap. The BAO is forwarded to the multisig in the same tx.
    /// @param user The swapper.
    /// @param baoIn The BAO pulled from the user.
    /// @param tideOut The TIDE sent to the user.
    event BaoConverted(address indexed user, uint256 baoIn, uint256 tideOut);

    /// @notice Emitted on a successful path-2 veBAO merkle claim.
    /// @param user The claimant.
    /// @param amount The TIDE paid (from the merkle leaf).
    event VeBaoClaimed(address indexed user, uint256 amount);

    /// @notice Emitted on a successful path-3 standard merkle claim.
    /// @param user The claimant.
    /// @param amount The TIDE paid (from the merkle leaf).
    event StandardClaimed(address indexed user, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Read-only eligibility preview for the path-2 veBAO claim (frontend helper).
    /// @dev Mirrors every on-chain `claimVeBao` check except the Merkle proof (which cannot be verified
    ///      in a `view` without the proof). `canClaimNow` is true only when all non-proof checks pass.
    struct VeClaimStatus {
        uint256 veEnd; // veBAO `locked__end(user)`
        uint256 lockedAmount; // current locked BAO (uint256 cast of `locked(user).amount`)
        uint256 baoRequired; // `tideToBao(tideAmount)`, rounded up
        uint256 minUnlockTime; // `endDate + 1` (strict `veEnd > endDate` extend-lock hint)
        bool canClaimNow; // all `claimVeBao` checks pass except the merkle proof
        bool alreadyClaimed; // `hasClaimedVeBao(user)`
        bool poolCapAvailable; // `totalTideSwapAndVe + tideAmount <= MAX_TIDE_SWAP_AND_VE`
    }

    /*//////////////////////////////////////////////////////////////
                            PATH 1 — SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice Path 1: swap BAO for TIDE at the fixed immutable rate during the claim window.
    /// @dev Pulls `baoAmount` BAO from the caller and forwards it to the multisig in the same tx; sends the
    ///      computed TIDE to the caller. Reverts below the minimum swap size or if a cap would be exceeded.
    /// @param baoAmount The BAO to convert.
    function convertBao(uint256 baoAmount) external;

    /*//////////////////////////////////////////////////////////////
                            PATH 2 — veBAO
    //////////////////////////////////////////////////////////////*/

    /// @notice Path 2: claim TIDE for an eligible veBAO position during the claim window.
    /// @dev The leaf is `(msg.sender, tideAmount)`. Requires `veEnd > endDate` and current `locked.amount`
    ///      >= `tideToBao(tideAmount)`. The merkle caps each user's max TIDE from the off-chain snapshot of
    ///      raw locked BAO at `SNAPSHOT_BLOCK`; the live lock check ensures they have not withdrawn below
    ///      what they are claiming. Pays `tideAmount` (authoritative from the leaf). Independent of paths 1 and 3.
    /// @param tideAmount The TIDE allocation encoded in the caller's merkle leaf.
    /// @param proof The merkle proof for `(msg.sender, tideAmount)` against `veBaoMerkleRoot`.
    function claimVeBao(uint256 tideAmount, bytes32[] calldata proof) external;

    /// @notice Read-only eligibility preview for `claimVeBao` (excludes the merkle proof check).
    /// @param user The account to preview.
    /// @param tideAmount The TIDE allocation to preview against.
    /// @return status The {VeClaimStatus} snapshot for `user`/`tideAmount`.
    function getVeClaimStatus(address user, uint256 tideAmount) external view returns (VeClaimStatus memory status);

    /*//////////////////////////////////////////////////////////////
                            PATH 3 — STANDARD
    //////////////////////////////////////////////////////////////*/

    /// @notice Path 3: claim TIDE from the standard merkle allocation during the claim window.
    /// @dev The leaf is `(msg.sender, tideAmount)`. Pays `tideAmount` (authoritative from the leaf) and is
    ///      bound by the separate `MAX_TIDE_STANDARD` cap. Independent of paths 1 and 2.
    /// @param tideAmount The TIDE allocation encoded in the caller's merkle leaf.
    /// @param proof The merkle proof for `(msg.sender, tideAmount)` against `standardMerkleRoot`.
    function claimStandard(uint256 tideAmount, bytes32[] calldata proof) external;

    /*//////////////////////////////////////////////////////////////
                            CONVERSION HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Converts BAO to TIDE at the fixed rate, rounding TIDE down.
    /// @param baoAmount The BAO amount.
    /// @return The TIDE amount (floor).
    function baoToTide(uint256 baoAmount) external view returns (uint256);

    /// @notice Converts a TIDE amount to the BAO required at the fixed rate, rounding BAO up.
    /// @param tideAmount The TIDE amount.
    /// @return The BAO amount (ceil).
    function tideToBao(uint256 tideAmount) external view returns (uint256);
}
