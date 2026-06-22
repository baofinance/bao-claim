// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IHarborTideDistributorErrors
/// @notice Typed revert reasons for {HarborTideDistributor_v1}.
/// @dev Custom errors only (no `require` strings), harbor `ITokenDistributor` style.
interface IHarborTideDistributorErrors {
    /*//////////////////////////////////////////////////////////////
                            WINDOW / TIMING
    //////////////////////////////////////////////////////////////*/

    /// @notice The claim window has not started (`block.timestamp < startDate`).
    error ClaimNotStarted();
    /// @notice The claim window has ended (`block.timestamp >= endDate`).
    error ClaimEnded();
    /// @notice The claim window is not over yet (sweep/recovery only after `endDate`).
    error ClaimNotOver();
    /// @notice Configuration is locked because `block.timestamp >= startDate` (immutable after window opens).
    error ConfigLocked();
    /// @notice The veBAO snapshot block has not been reached (`block.number < SNAPSHOT_BLOCK`).
    error SnapshotNotReached();

    /*//////////////////////////////////////////////////////////////
                            CLAIM / PROOF
    //////////////////////////////////////////////////////////////*/

    /// @notice The caller has already claimed on this path.
    error AlreadyClaimed();
    /// @notice The supplied Merkle proof does not match the configured root for `(account, tideAmount)`.
    error InvalidProof();
    /// @notice The contract does not hold enough TIDE to satisfy the transfer.
    error InsufficientBalance();

    /*//////////////////////////////////////////////////////////////
                            PATH 1 — SWAP
    //////////////////////////////////////////////////////////////*/

    /// @notice The computed TIDE output is below the minimum swap size (`MIN_TIDE_OUT`).
    error BelowMinSwap();
    /// @notice The global BAO conversion cap (`MAX_BAO`) would be exceeded.
    error BaoCapExceeded();
    /// @notice The shared swap + veBAO TIDE cap (`MAX_TIDE_SWAP_AND_VE`) would be exceeded.
    error TideSwapVeCapExceeded();

    /*//////////////////////////////////////////////////////////////
                            PATH 2 — veBAO
    //////////////////////////////////////////////////////////////*/

    /// @notice The veBAO lock ends at or before `endDate` (`locked__end <= endDate`).
    error LockEndTooEarly();
    /// @notice Current `locked.amount` is below the BAO equivalent of the merkle allocation (`tideToBao(tideAmount)`).
    error InsufficientLocked();

    /*//////////////////////////////////////////////////////////////
                            PATH 3 — STANDARD
    //////////////////////////////////////////////////////////////*/

    /// @notice The standard merkle TIDE cap (`MAX_TIDE_STANDARD`) would be exceeded.
    error TideStandardCapExceeded();

    /*//////////////////////////////////////////////////////////////
                            ADMIN / SWEEP
    //////////////////////////////////////////////////////////////*/

    /// @notice A zero address was supplied where a non-zero address is required.
    error InvalidAddress();
    /// @notice A zero or otherwise invalid amount was supplied.
    error InvalidAmount();
    /// @notice The provided start/end dates are invalid (`startDate >= endDate`).
    error InvalidDates();
    /// @notice There is nothing to sweep (zero balance).
    error NothingToSweep();
    /// @notice The TIDE claim token (or BAO swap token) cannot be recovered via `recoverySweep`.
    error CannotRecoverClaimToken();
}
