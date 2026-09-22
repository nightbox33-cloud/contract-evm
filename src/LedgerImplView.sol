// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "./dataLayout/LedgerDataLayout.sol";
import "./interface/ILedgerImplView.sol";
import "./interface/IVaultManager.sol";
import "./library/typesHelper/AccountTypeHelper.sol";

/// @title Ledger contract, implementation part View contract, for resolve EIP170 limit
/// @author Orderly_Rubick
/// @notice This contract contains all view functions for the Ledger
contract LedgerImplView is ILedgerImplView, OwnableUpgradeable, LedgerDataLayout {
    using AccountTypeHelper for AccountTypes.Account;

    constructor() {
        _disableInitializers();
    }

    /// @notice Get the amount of a token frozen balance for a given account and the corresponding withdrawNonce
    /// @param accountId accountId to query
    /// @param withdrawNonce withdrawNonce to query
    /// @param tokenHash tokenHash to query
    /// @return uint128 frozen value
    function getFrozenWithdrawNonce(bytes32 accountId, uint64 withdrawNonce, bytes32 tokenHash)
        external
        view
        override
        returns (uint128)
    {
        return userLedger[accountId].getFrozenWithdrawNonceBalance(withdrawNonce, tokenHash);
    }

    /// @notice omni batch get
    /// @param accountIds accountId list to query
    /// @param tokens token list to query
    /// @param symbols symbol list to query
    /// @return accountSnapshots account snapshot list for the given tokens and symbols
    function batchGetUserLedger(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        public
        view
        override
        returns (AccountTypes.AccountSnapshot[] memory accountSnapshots)
    {
        uint256 accountIdLength = accountIds.length;
        uint256 tokenLength = tokens.length;
        uint256 symbolLength = symbols.length;

        accountSnapshots = new AccountTypes.AccountSnapshot[](accountIdLength);
        for (uint256 i = 0; i < accountIdLength; ++i) {
            bytes32 accountId = accountIds[i];

            AccountTypes.AccountTokenBalances[] memory tokenInner = new AccountTypes.AccountTokenBalances[](tokenLength);
            tokenInner = _getUserTokenBalances(accountId, tokens);

            AccountTypes.AccountPerpPositions[] memory symbolInner = new AccountTypes.AccountPerpPositions[](symbolLength);
            symbolInner = _getUserPerpPositions(accountId, symbols);

            accountSnapshots[i] = _getUserAccountSnapshot(accountId, tokenInner, symbolInner);
        }
    }

    /// @notice omni batch get with default tokens and symbols
    /// @param accountIds accountId list to query
    /// @return accountSnapshots account snapshot list
    function batchGetUserLedger(bytes32[] calldata accountIds)
        external
        view
        override
        returns (AccountTypes.AccountSnapshot[] memory)
    {
        bytes32[] memory tokens = vaultManager.getAllAllowedToken();
        bytes32[] memory symbols = vaultManager.getAllAllowedSymbol();
        return batchGetUserLedger(accountIds, tokens, symbols);
    }

    /// @notice Get user token balance
    /// @param accountId accountId to query
    /// @param tokenHash tokenHash to query
    /// @return balance
    function getUserTokenBalance(bytes32 accountId, bytes32 tokenHash) external view override returns (int128) {
        return userLedger[accountId].getBalance(tokenHash);
    }

    /// @notice omni batch get v3 with iso positions
    /// @param accountIds accountId list to query
   
    /// @return accountSnapshots account snapshot v3 list
    function batchGetUserLedgerV3(bytes32[] calldata accountIds)
        public
        view
        override
        returns (AccountTypes.AccountSnapshotV3[] memory accountSnapshots)
    {
        uint256 accountIdLength = accountIds.length;
        bytes32[] memory tokens = vaultManager.getAllAllowedToken();
        bytes32[] memory symbols = vaultManager.getAllAllowedSymbol();
        uint256 tokenLength = tokens.length;
        uint256 symbolLength = symbols.length;

        accountSnapshots = new AccountTypes.AccountSnapshotV3[](accountIdLength);
        for (uint256 i = 0; i < accountIdLength; ++i) {
            bytes32 accountId = accountIds[i];

            AccountTypes.AccountTokenBalances[] memory tokenBalances = new AccountTypes.AccountTokenBalances[](tokenLength);
            tokenBalances = _getUserTokenBalances(accountId, tokens);

            AccountTypes.AccountPerpPositions[] memory perpPositions = new AccountTypes.AccountPerpPositions[](symbolLength);
            perpPositions = _getUserPerpPositions(accountId, symbols);

            AccountTypes.AccountIsoPerpPositions[] memory isoPerpPosition = new AccountTypes.AccountIsoPerpPositions[](symbolLength);
            isoPerpPosition = _getUserIsoPerpPositions(accountId, symbols);

            accountSnapshots[i] = _getUserAccountSnapshotV3(accountId, tokenBalances, perpPositions, isoPerpPosition);
        }
    }

    /// @param accountIds accountId list to query
    /// @param tokens token list to query
    /// @param symbols symbol list to query
    /// @return accountSnapshots account snapshot list for the given tokens and symbols
     function batchGetUserLedgerV3(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        public
        view
        override
        returns (AccountTypes.AccountSnapshotV3[] memory accountSnapshots)
    {
        uint256 accountIdLength = accountIds.length;
        uint256 tokenLength = tokens.length;
        uint256 symbolLength = symbols.length;

        accountSnapshots = new AccountTypes.AccountSnapshotV3[](accountIdLength);
        for (uint256 i = 0; i < accountIdLength; ++i) {
            bytes32 accountId = accountIds[i];

            AccountTypes.AccountTokenBalances[] memory tokenInner = new AccountTypes.AccountTokenBalances[](tokenLength);
            tokenInner = _getUserTokenBalances(accountId, tokens);

            AccountTypes.AccountPerpPositions[] memory symbolInner = new AccountTypes.AccountPerpPositions[](symbolLength);
            symbolInner = _getUserPerpPositions(accountId, symbols);

            AccountTypes.AccountIsoPerpPositions[] memory isoPerpPosition = new AccountTypes.AccountIsoPerpPositions[](symbolLength);
            isoPerpPosition = _getUserIsoPerpPositions(accountId, symbols);

            accountSnapshots[i] = _getUserAccountSnapshotV3(accountId, tokenInner, symbolInner, isoPerpPosition);
        }
    }

    /// @notice batch get user balance
    /// @param accountIds accountId list to query
    /// @return snapshots account balance snapshot list
    function batchGetUserBalance(bytes32[] calldata accountIds)
        external
        view
        override
        returns (AccountTypes.AccountBalanceSnapshot[] memory)
    {
        bytes32[] memory tokens = vaultManager.getAllAllowedToken();
        uint256 accountIdLength = accountIds.length;

        AccountTypes.AccountBalanceSnapshot[] memory snapshots =
            new AccountTypes.AccountBalanceSnapshot[](accountIdLength);
        for (uint256 i = 0; i < accountIdLength; ++i) {
            bytes32 accountId = accountIds[i];
            AccountTypes.AccountTokenBalances[] memory tokenBalances = _getUserTokenBalances(accountId, tokens);
            snapshots[i] = AccountTypes.AccountBalanceSnapshot({
                accountId: accountId,
                brokerHash: userLedger[accountId].brokerHash,
                userAddress: userLedger[accountId].userAddress,
                tokenBalances: tokenBalances
            });
        }
        return snapshots;
    }

    /// @notice Get user escrow balance
    /// @param accountId accountId to query
    /// @param tokenHash tokenHash to query
    /// @return escrow balance
    function getUserEscrowBalance(bytes32 accountId, bytes32 tokenHash) external view override returns (uint128) {
        return escrowBalances[accountId][tokenHash];
    }

    /// @notice Get user total frozen balance
    /// @param accountId accountId to query
    /// @param tokenHash tokenHash to query
    /// @return total frozen balance
    function getUserTotalFrozenBalance(bytes32 accountId, bytes32 tokenHash) external view override returns (uint128) {
        return userLedger[accountId].getFrozenTotalBalance(tokenHash);
    }


    /// @notice Get balance transfer state
    /// @param transferId transferId to query
    /// @return InternalTransferTrack
    function getBalanceTransferState(uint256 transferId)
        external
        view
        override
        returns (EventTypes.InternalTransferTrack memory)
    {
        return transfers[transferId];
    }

    // =================== internal view helpers =================== //

    function _getUserTokenBalances(bytes32 accountId, bytes32[] memory tokens)
        internal
        view
        returns (AccountTypes.AccountTokenBalances[] memory)
    {
        uint256 tokenLength = tokens.length;
        require(tokenLength > 0, "Empty tokens");
        AccountTypes.AccountTokenBalances[] memory tokenBalances = new AccountTypes.AccountTokenBalances[](tokenLength);
        AccountTypes.Account storage account = userLedger[accountId];
        for (uint256 i = 0; i < tokenLength; ++i) {
            bytes32 tokenHash = tokens[i];
            tokenBalances[i] = AccountTypes.AccountTokenBalances({
                tokenHash: tokenHash,
                balance: account.getBalance(tokenHash),
                frozenBalance: account.getFrozenTotalBalance(tokenHash)
            });
        }
        return tokenBalances;
    }

    function _getUserPerpPositions(bytes32 accountId, bytes32[] memory symbols)
        internal
        view
        returns (AccountTypes.AccountPerpPositions[] memory)
    {
        uint256 symbolLength = symbols.length;
        require(symbolLength > 0, "Empty symbols");
        AccountTypes.AccountPerpPositions[] memory perpPositions = new AccountTypes.AccountPerpPositions[](symbolLength);
        AccountTypes.Account storage account = userLedger[accountId];
        for (uint256 i = 0; i < symbolLength; ++i) {
            bytes32 symbolHash = symbols[i];
            AccountTypes.PerpPosition storage perpPosition = account.perpPositions[symbolHash];
            perpPositions[i] = AccountTypes.AccountPerpPositions({
                symbolHash: symbolHash,
                positionQty: perpPosition.positionQty,
                costPosition: perpPosition.costPosition,
                lastSumUnitaryFundings: perpPosition.lastSumUnitaryFundings,
                lastExecutedPrice: perpPosition.lastExecutedPrice,
                lastSettledPrice: perpPosition.lastSettledPrice,
                averageEntryPrice: perpPosition.averageEntryPrice,
                openingCost: perpPosition.openingCost,
                lastAdlPrice: perpPosition.lastAdlPrice
            });
        }

        return perpPositions;
    }

    function _getUserIsoPerpPositions(bytes32 accountId, bytes32[] memory symbols)
        internal
        view
        returns (AccountTypes.AccountIsoPerpPositions[] memory)
    {
        uint256 symbolLength = symbols.length;
        require(symbolLength > 0, "Empty symbols");
        AccountTypes.AccountIsoPerpPositions[] memory isoPositions = new AccountTypes.AccountIsoPerpPositions[](symbolLength);
        AccountTypes.Account storage account = userLedger[accountId];

        bytes32[] memory allowedAssets = vaultManager.getAllAllowedToken();

        for (uint256 i = 0; i < symbolLength; ++i) {
            bytes32 symbolHash = symbols[i];
            AccountTypes.IsoPerpPosition storage isoPerpPosition = account.isoPerpPositions[symbolHash];

            AccountTypes.AccountMargins[] memory margins = new AccountTypes.AccountMargins[](allowedAssets.length);

            for (uint256 j = 0; j < allowedAssets.length; ++j) {
                bytes32 marginAssetHash = allowedAssets[j];
                margins[j] = AccountTypes.AccountMargins({
                    marginAssetHash: marginAssetHash,
                    margin: isoPerpPosition.margins[marginAssetHash]
                });
            }

            isoPositions[i] = AccountTypes.AccountIsoPerpPositions({
                symbolHash: symbolHash,
                positionQty: isoPerpPosition.positionQty,
                costPosition: isoPerpPosition.costPosition,
                lastSumUnitaryFundings: isoPerpPosition.lastSumUnitaryFundings,
                lastExecutedPrice: isoPerpPosition.lastExecutedPrice,
                lastSettledPrice: isoPerpPosition.lastSettledPrice,
                averageEntryPrice: isoPerpPosition.averageEntryPrice,
                openingCost: isoPerpPosition.openingCost,
                lastAdlPrice: isoPerpPosition.lastAdlPrice,
                margins: margins
            });
        }

        return isoPositions;
    }

    function _getUserAccountSnapshot(
        bytes32 accountId,
        AccountTypes.AccountTokenBalances[] memory tokenBalances,
        AccountTypes.AccountPerpPositions[] memory perpPositions
    ) internal view returns (AccountTypes.AccountSnapshot memory) {
        AccountTypes.Account storage account = userLedger[accountId];
        return AccountTypes.AccountSnapshot({
            accountId: accountId,
            brokerHash: account.brokerHash,
            userAddress: account.userAddress,
            lastWithdrawNonce: account.lastWithdrawNonce,
            lastPerpTradeId: account.lastPerpTradeId,
            lastEngineEventId: account.lastEngineEventId,
            lastDepositEventId: account.lastDepositEventId,
            tokenBalances: tokenBalances,
            perpPositions: perpPositions,
            lastDepositSrcChainId: account.lastDepositSrcChainId,
            lastDepositSrcChainNonce: account.lastDepositSrcChainNonce
        });
    }

    function _getUserAccountSnapshotV3(
        bytes32 accountId,
        AccountTypes.AccountTokenBalances[] memory tokenBalances,
        AccountTypes.AccountPerpPositions[] memory perpPositions,
        AccountTypes.AccountIsoPerpPositions[] memory isoPerpPositions
    ) internal view returns (AccountTypes.AccountSnapshotV3 memory) {
        AccountTypes.Account storage account = userLedger[accountId];
        return AccountTypes.AccountSnapshotV3({
            accountId: accountId,
            brokerHash: account.brokerHash,
            userAddress: account.userAddress,
            lastWithdrawNonce: account.lastWithdrawNonce,
            lastPerpTradeId: account.lastPerpTradeId,
            lastEngineEventId: account.lastEngineEventId,
            lastDepositEventId: account.lastDepositEventId,
            tokenBalances: tokenBalances,
            perpPositions: perpPositions,
            isoPerpPositions: isoPerpPositions,
            lastDepositSrcChainId: account.lastDepositSrcChainId,
            lastDepositSrcChainNonce: account.lastDepositSrcChainNonce
        });
    }
}
