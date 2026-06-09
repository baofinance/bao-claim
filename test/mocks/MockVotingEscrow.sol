// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IVotingEscrow} from "@tide/interfaces/IVotingEscrow.sol";

/// @title MockVotingEscrow
/// @notice Configurable veBAO mock for tests: per-user `locked` (amount + end) and `balanceOfAt` snapshot.
/// @dev `balanceOfAt` ignores the block argument and returns the configured snapshot value.
contract MockVotingEscrow is IVotingEscrow {
    mapping(address => LockedBalance) private _locked;
    mapping(address => uint256) private _snapshot;

    /// @notice Sets the current locked record for `addr`.
    /// @param addr The account.
    /// @param amount The raw locked BAO amount (int128).
    /// @param end The lock end timestamp.
    function setLocked(address addr, int128 amount, uint256 end) external {
        _locked[addr] = LockedBalance({amount: amount, end: end});
    }

    /// @notice Sets the BAO-equivalent snapshot balance returned by `balanceOfAt` for `addr`.
    /// @param addr The account.
    /// @param balance The snapshot voting power.
    function setSnapshot(address addr, uint256 balance) external {
        _snapshot[addr] = balance;
    }

    /// @inheritdoc IVotingEscrow
    function locked(address addr) external view returns (LockedBalance memory) {
        return _locked[addr];
    }

    /// @inheritdoc IVotingEscrow
    function locked__end(address addr) external view returns (uint256) {
        return _locked[addr].end;
    }

    /// @inheritdoc IVotingEscrow
    function balanceOfAt(address addr, uint256) external view returns (uint256) {
        return _snapshot[addr];
    }
}
