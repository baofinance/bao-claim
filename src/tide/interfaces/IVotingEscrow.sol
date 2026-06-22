// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title IVotingEscrow
/// @notice Minimal external interface for the veBAO voting escrow (`0x8bf70dfe40f07a5ab715f7e888478d9d3680a2b6`).
/// @dev Only the read functions consumed by {HarborTideDistributor_v1} path 2 are declared. veBAO is a
///      Curve-style voting escrow: `locked` returns the raw locked BAO (`int128 amount`) and lock end.
///      Path 2 gates on `locked` only; `balanceOfAt` is retained for integrators querying ve power.
interface IVotingEscrow {
    /// @notice Curve-style locked balance record.
    /// @dev `amount` is the raw locked BAO (signed in the source contract, always non-negative in practice).
    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    /// @notice Returns the locked balance record for `addr`.
    /// @param addr The account to query.
    /// @return The {LockedBalance} (raw BAO amount + unlock timestamp).
    function locked(address addr) external view returns (LockedBalance memory);

    /// @notice Returns the lock end (unlock timestamp) for `addr`.
    /// @param addr The account to query.
    /// @return The unix timestamp at which the lock unlocks.
    function locked__end(address addr) external view returns (uint256);

    /// @notice Returns the voting power (BAO-equivalent snapshot) of `addr` at a historical block.
    /// @param addr The account to query.
    /// @param blockNumber The historical block number to read.
    /// @return The voting power at `blockNumber`.
    function balanceOfAt(address addr, uint256 blockNumber) external view returns (uint256);
}
