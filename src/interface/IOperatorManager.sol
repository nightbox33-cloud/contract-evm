// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

import "../library/types/AccountTypes.sol";
import "../library/types/PerpTypes.sol";
import "../library/types/EventTypes.sol";
import "../library/types/MarketTypes.sol";
import "../library/types/RebalanceTypes.sol";
import "./error/IError.sol";
import "./IOperatorManagerEvent.sol";

interface IOperatorManager is IError, IOperatorManagerEvent {
    function initialize() external;
    function initBizTypeToSelector() external;

    // operator call futures trade upload
    function futuresTradeUpload(PerpTypes.FuturesTradeUploadData calldata data) external;
    // operator call iso futures trade upload
    function futuresTradeUploadV3(PerpTypes.FuturesTradeUploadDataV3 calldata data) external;
    // operator call futures trade upload V4 (V3 + isInsuranceAccount flag per trade)
    function futuresTradeUploadV4(PerpTypes.FuturesTradeUploadDataV4 calldata data) external;
    // operator call event upload
    function eventUpload(EventTypes.EventUpload calldata data) external;
    // operator call perp market info
    function perpPriceUpload(MarketTypes.UploadPerpPrice calldata data) external;
    function sumUnitaryFundingsUpload(MarketTypes.UploadSumUnitaryFundings calldata data) external;
    // operator call rebalance mint
    function rebalanceBurnUpload(RebalanceTypes.RebalanceBurnUploadData calldata) external;
    function rebalanceMintUpload(RebalanceTypes.RebalanceMintUploadData calldata) external;
    // operator call ping
    function operatorPing() external;

    // check if engine down
    function checkEngineDown() external returns (bool);

    // operator call permissionless listing: set allowed symbol (CEFI-signed)
    function setAllowedSymbol(bytes32 _symbolHash, bool _allowed, uint64 _sequenceId, uint256 _chainId, bytes calldata _cefiSignature)
        external;
    
    // admin call
    function setOperator(address _operatorAddress) external;
    function setLedger(address _ledger) external;
    function setMarketManager(address _marketManagerAddress) external;
    function setEngineSpotTradeUploadAddress(address _engineSpotTradeUploadAddress) external;
    function setEnginePerpTradeUploadAddress(address _enginePerpTradeUploadAddress) external;
    function setEngineEventUploadAddress(address _engineEventUploadAddress) external;
    function setEngineMarketUploadAddress(address _engineMarketUploadAddress) external;
    function setEngineRebalanceUploadAddress(address _engineRebalanceUploadAddress) external;
    function setOperatorManagerZipAddress(address _operatorManagerZipAddress) external;
    function setOperatorManagerImplA(address _operatorManagerImplA) external;
    function setOperatorManagerImplB(address _operatorManagerImplB) external;
    function setVaultManager(address _vaultManager) external;
    function setPermissionlessListingSignerAddress(address _permissionlessListingSignerAddress) external;
}
