// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "../../src/Ledger.sol";

contract LedgerCheater is Ledger {
    using AccountTypeHelper for AccountTypes.Account;

    function cheatDeposit(bytes32 accountId, bytes32 tokenHash, uint128 tokenAmount, uint256 srcChainId) external {
        AccountTypes.Account storage account = userLedger[accountId];

        account.addBalance(tokenHash, tokenAmount);
        vaultManager.addBalance(tokenHash, srcChainId, tokenAmount);
        account.lastDepositEventId = _newGlobalDepositId();
    }

    function cheatSubVaultBalance(bytes32 tokenHash, uint128 deltaBalance, uint256 srcChainId) public {
        vaultManager.subBalance(tokenHash, srcChainId, deltaBalance);
    }

    function cheatUserWithdrawNonce(bytes32 accountId, uint64 nonce) external {
         AccountTypes.Account storage account = userLedger[accountId];
         account.lastWithdrawNonce = nonce;
    }

    function cheatUserEscrowBalance(bytes32 accountId, bytes32 tokenHash, uint128 tokenAmount) external {
        escrowBalances[accountId][tokenHash] = tokenAmount;
    }


    function cheatSetUserPosition(bytes32 accountId, bytes32 symbolHash, AccountTypes.PerpPosition memory position)
        external
    {
        AccountTypes.Account storage account = userLedger[accountId];
        account.perpPositions[symbolHash] = position;
    }

    function cheatGetUserEscrowBalance(bytes32 accountId, bytes32 tokenHash) public view returns (uint128) {
        return escrowBalances[accountId][tokenHash];
    }

    // get userLedger balance
    function getUserLedgerBalance(bytes32 accountId, bytes32 tokenHash) public view returns (int128) {
        return userLedger[accountId].getBalance(tokenHash);
    }

    // get userLedger lastEngineEventId
    function getLastPerpTradeId(bytes32 accountId) public view returns (uint64) {
        return userLedger[accountId].lastPerpTradeId;
    }

    function getUserLedgerLastEngineEventId(bytes32 accountId) public view returns (uint64) {
        return userLedger[accountId].getLastEngineEventId();
    }

    // get frozen total balance
    function getFrozenTotalBalance(bytes32 accountId, bytes32 tokenHash) public view returns (uint128) {
        return userLedger[accountId].getFrozenTotalBalance(tokenHash);
    }

    // get perp position
    function getPerpPosition(bytes32 accountId, bytes32 symbolHash)
        public
        view
        returns (AccountTypes.PerpPosition memory perpPosition)
    {
        perpPosition = userLedger[accountId].perpPositions[symbolHash];
    }

    // set iso perp position (without margins since mapping can't be set in memory)
    function cheatSetUserIsoPosition(
        bytes32 accountId,
        bytes32 symbolHash,
        int128 positionQty,
        int128 costPosition,
        int128 lastSumUnitaryFundings,
        uint128 lastExecutedPrice,
        uint128 lastSettledPrice,
        uint128 averageEntryPrice,
        int128 openingCost,
        uint128 lastAdlPrice
    ) external {
        AccountTypes.Account storage account = userLedger[accountId];
        AccountTypes.IsoPerpPosition storage isoPos = account.isoPerpPositions[symbolHash];
        isoPos.positionQty = positionQty;
        isoPos.costPosition = costPosition;
        isoPos.lastSumUnitaryFundings = lastSumUnitaryFundings;
        isoPos.lastExecutedPrice = lastExecutedPrice;
        isoPos.lastSettledPrice = lastSettledPrice;
        isoPos.averageEntryPrice = averageEntryPrice;
        isoPos.openingCost = openingCost;
        isoPos.lastAdlPrice = lastAdlPrice;
    }

    // set iso margin for a position
    function cheatSetUserIsoMargin(bytes32 accountId, bytes32 symbolHash, bytes32 marginAssetHash, int128 marginAmount)
        external
    {
        AccountTypes.Account storage account = userLedger[accountId];
        account.isoPerpPositions[symbolHash].margins[marginAssetHash] = marginAmount;
    }

    // get iso perp position fields (without margins mapping)
    function getIsoPerpPosition(bytes32 accountId, bytes32 symbolHash)
        public
        view
        returns (
            int128 positionQty,
            int128 costPosition,
            int128 lastSumUnitaryFundings,
            uint128 lastExecutedPrice,
            uint128 lastSettledPrice,
            uint128 averageEntryPrice,
            int128 openingCost,
            uint128 lastAdlPrice
        )
    {
        AccountTypes.IsoPerpPosition storage isoPos = userLedger[accountId].isoPerpPositions[symbolHash];
        return (
            isoPos.positionQty,
            isoPos.costPosition,
            isoPos.lastSumUnitaryFundings,
            isoPos.lastExecutedPrice,
            isoPos.lastSettledPrice,
            isoPos.averageEntryPrice,
            isoPos.openingCost,
            isoPos.lastAdlPrice
        );
    }

    // get iso perp position scalar fields packed as a PerpPosition (same 8 fields, same order; margins mapping excluded)
    function getIsoPerpPositionAsPerp(bytes32 accountId, bytes32 symbolHash)
        public
        view
        returns (AccountTypes.PerpPosition memory p)
    {
        AccountTypes.IsoPerpPosition storage isoPos = userLedger[accountId].isoPerpPositions[symbolHash];
        p.positionQty = isoPos.positionQty;
        p.costPosition = isoPos.costPosition;
        p.lastSumUnitaryFundings = isoPos.lastSumUnitaryFundings;
        p.lastExecutedPrice = isoPos.lastExecutedPrice;
        p.lastSettledPrice = isoPos.lastSettledPrice;
        p.averageEntryPrice = isoPos.averageEntryPrice;
        p.openingCost = isoPos.openingCost;
        p.lastAdlPrice = isoPos.lastAdlPrice;
    }

    // get iso margin
    function getIsoMargin(bytes32 accountId, bytes32 symbolHash, bytes32 marginAssetHash)
        public
        view
        returns (int128)
    {
        return userLedger[accountId].isoPerpPositions[symbolHash].margins[marginAssetHash];
    }

    function _newGlobalEventId() internal returns (uint64) {
        return ++globalEventId;
    }

    function _newGlobalDepositId() internal returns (uint64) {
        return ++globalDepositId;
    }
}
