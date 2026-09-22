// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

/// @title PerpTypes library
/// @author Orderly_Rubick
library PerpTypes {
    // FuturesTradeUploadData
    struct FuturesTradeUploadData {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint64 batchId;
        uint8 count;
        FuturesTradeUpload[] trades;
    }

    struct FuturesTradeUpload {
        bytes32 accountId;
        bytes32 symbolHash;
        bytes32 feeAssetHash;
        int128 tradeQty;
        int128 notional;
        uint128 executedPrice;
        int128 fee;
        int128 sumUnitaryFundings;
        uint64 tradeId;
        uint64 matchId;
        uint64 timestamp;
        bool side; // buy (false) or sell (true)
    }

    struct FuturesTradeUploadDataV3 {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint64 batchId;
        uint8 count;
        FuturesTradeUploadV3[] trades;
    }

    struct FuturesTradeUploadV3 {
        bytes32 accountId;
        bytes32 symbolHash;
        bytes32 feeAssetHash;
        int128 tradeQty;
        int128 notional;
        uint128 executedPrice;
        int128 fee;
        int128 sumUnitaryFundings;
        uint64 tradeId;
        uint64 matchId;
        uint64 timestamp;
        bool side;
        uint8 marginMode;
        bytes32 isoMarginAssetHash;
        int128 marginFromCross;  // margin transfered from cross to isolated perp position
    }

    // V4: same as V3, with `isInsuranceAccount` appended at the end of each trade
    struct FuturesTradeUploadDataV4 {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint64 batchId;
        uint8 count;
        FuturesTradeUploadV4[] trades;
    }

    /// @dev Field order MUST stay identical to FuturesTradeUploadV3 with `isInsuranceAccount` appended,
    ///      because the engine signature covers abi.encode(batchId, count, trades).
    struct FuturesTradeUploadV4 {
        bytes32 accountId;
        bytes32 symbolHash;
        bytes32 feeAssetHash;
        int128 tradeQty;
        int128 notional;
        uint128 executedPrice;
        int128 fee;
        int128 sumUnitaryFundings;
        uint64 tradeId;
        uint64 matchId;
        uint64 timestamp;
        bool side;
        uint8 marginMode;
        bytes32 isoMarginAssetHash;
        int128 marginFromCross;  // margin transfered from cross to isolated perp position
        bool isInsuranceAccount; // true => skip averageEntryPrice / openingCost recomputation for this trade
    }
}
