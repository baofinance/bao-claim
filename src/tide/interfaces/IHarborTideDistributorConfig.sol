// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IHarborTideDistributorConfig
/// @notice Owner / `CONFIG_ROLE` governance API for {HarborTideDistributor_v1}.
/// @dev Merkle roots and the multisig may only be updated before `startDate`. Sweep and recovery are
///      owner-only and only callable after `endDate`. Dates, caps, rate, and token addresses are immutable.
interface IHarborTideDistributorConfig {
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the veBAO merkle root is updated (before `startDate`).
    /// @param root The new veBAO merkle root.
    event VeBaoMerkleRootUpdated(bytes32 root);

    /// @notice Emitted when the standard merkle root is updated (before `startDate`).
    /// @param root The new standard merkle root.
    event StandardMerkleRootUpdated(bytes32 root);

    /// @notice Emitted when the multisig address is updated (before `startDate`).
    /// @param multisig The new multisig address.
    event MultisigUpdated(address multisig);

    /// @notice Emitted when unclaimed TIDE is swept to the multisig after `endDate`.
    /// @param to The recipient (multisig).
    /// @param amount The TIDE swept.
    event Sweep(address indexed to, uint256 amount);

    /// @notice Emitted when a stray (non-TIDE, non-BAO) token is recovered after `endDate`.
    /// @param token The recovered token.
    /// @param amount The amount recovered.
    event Recovered(address indexed token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                            ROOT / CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets the path-2 veBAO merkle root. Owner or `CONFIG_ROLE`, before `startDate` only.
    /// @param root The new veBAO merkle root.
    function setVeBaoMerkleRoot(bytes32 root) external;

    /// @notice Sets the path-3 standard merkle root. Owner or `CONFIG_ROLE`, before `startDate` only.
    /// @param root The new standard merkle root.
    function setStandardMerkleRoot(bytes32 root) external;

    /// @notice Sets the multisig (BAO recipient + sweep destination). Owner only, before `startDate` only.
    /// @param multisig The new multisig address.
    function setMultisig(address multisig) external;

    /*//////////////////////////////////////////////////////////////
                            SWEEP / RECOVERY
    //////////////////////////////////////////////////////////////*/

    /// @notice Sweeps all remaining TIDE to the multisig. Owner only, after `endDate` only.
    function sweep() external;

    /// @notice Recovers a stray token (not TIDE, not BAO) to the multisig. Owner only, after `endDate` only.
    /// @param token The token to recover.
    function recoverySweep(address token) external;
}
