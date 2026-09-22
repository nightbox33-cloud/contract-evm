// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

import "../library/types/AccountTypes.sol";
import "../library/types/EventTypes.sol";

/// @title ILedgerImplView interface
/// @author Orderly_Rubick
/// @notice Interface for LedgerImplView contract which contains all view functions
interface ILedgerImplView {
    /// @notice Get the amount of a token frozen balance for a given account and the corresponding withdrawNonce
    /// @param accountId accountId to query
    /// @param withdrawNonce withdrawNonce to query
    /// @param tokenHash tokenHash to query
    /// @return uint128 frozen value
    function getFrozenWithdrawNonce(bytes32 accountId, uint64 withdrawNonce, bytes32 tokenHash)
        external
        view
        returns (uint128);

    /// @notice omni batch get
    /// @param accountIds accountId list to query
    /// @param tokens token list to query
    /// @param symbols symbol list to query
    /// @return accountSnapshots account snapshot list for the given tokens and symbols
    function batchGetUserLedger(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        external
        view
        returns (AccountTypes.AccountSnapshot[] memory accountSnapshots);

    /// @notice omni batch get with default tokens and symbols
    /// @param accountIds accountId list to query
    /// @return accountSnapshots account snapshot list
    function batchGetUserLedger(bytes32[] calldata accountIds)
        external
        view
        returns (AccountTypes.AccountSnapshot[] memory);

    /// @notice Get user token balance
    /// @param accountId accountId to query
    /// @param tokenHash tokenHash to query
    /// @return balance
    function getUserTokenBalance(bytes32 accountId, bytes32 tokenHash) external view returns (int128);

    /// @notice omni batch get v3 with iso positions
    /// @param accountIds accountId list to query
    /// @param tokens token list to query
    /// @param symbols symbol list to query
    /// @return accountSnapshots account snapshot list for the given tokens and symbols
    function batchGetUserLedgerV3(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        external
        view
        returns (AccountTypes.AccountSnapshotV3[] memory accountSnapshots);

    /// @notice omni batch get v3 with iso positions
    /// @param accountIds accountId list to query
    /// @return accountSnapshots account snapshot v3 list
    function batchGetUserLedgerV3(bytes32[] calldata accountIds)
        external
        view
        returns (AccountTypes.AccountSnapshotV3[] memory accountSnapshots);

    /// @notice batch get user balance
    /// @param accountIds accountId list to query
    /// @return snapshots account balance snapshot list
    function batchGetUserBalance(bytes32[] calldata accountIds)
        external
        view
        returns (AccountTypes.AccountBalanceSnapshot[] memory);

    /// @notice Get user escrow balance
    /// @param accountId accountId to query
    /// @param tokenHash tokenHash to query
    /// @return escrow balance
    function getUserEscrowBalance(bytes32 accountId, bytes32 tokenHash) external view returns (uint128);

    /// @notice Get user total frozen balance
    /// @param accountId accountId to query
    /// @param tokenHash tokenHash to query
    /// @return total frozen balance
    function getUserTotalFrozenBalance(bytes32 accountId, bytes32 tokenHash) external view returns (uint128);

    /// @notice Get balance transfer state
    /// @param transferId transferId to query
    /// @return InternalTransferTrack
    function getBalanceTransferState(uint256 transferId)
        external
        view
        returns (EventTypes.InternalTransferTrack memory);
}
