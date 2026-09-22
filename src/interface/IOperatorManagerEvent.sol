// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

interface IOperatorManagerEvent {
    event FuturesTradeUpload(uint64 indexed batchId);
    event FuturesTradeUploadV3(uint64 indexed batchId);
    event FuturesTradeUploadV4(uint64 indexed batchId);
    event EventUpload(uint64 indexed batchId);
    event ChangeEngineUpload(uint8 indexed types, address oldAddress, address newAddress);
    event ChangeOperator(uint8 indexed types, address oldAddress, address newAddress);
    event ChangeMarketManager(address oldAddress, address newAddress);
    event ChangeLedger(address oldAddress, address newAddress);
    event ChangeOperatorImplA(address oldAddress, address newAddress);
    event ChangeOperatorImplB(address oldAddress, address newAddress);
    event RebalanceBurnUpload(uint64 indexed rebalanceId);
    event RebalanceMintUpload(uint64 indexed rebalanceId);

    // @Ray add event for change vault manager
    event SetAllowedSymbolByOperator(bytes32 indexed symbolHash, bool allowed, uint64 indexed sequenceId);
    event SetVaultManager(address oldAddress, address newAddress);
    event SetPermissionlessListingSignerAddress(address oldAddress, address newAddress);

    // @depreacted
    // All events below are deprecated
    // Keep them for indexer backward compatibility
    event FuturesTradeUpload(uint64 indexed batchId, uint256 blocktime);
    event EventUpload(uint64 indexed batchId, uint256 blocktime);
}
