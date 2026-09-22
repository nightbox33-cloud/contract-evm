// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

import "../library/types/AccountTypes.sol";
import "../library/types/PerpTypes.sol";
import "../library/types/EventTypes.sol";
import "../library/types/MarketTypes.sol";
import "../library/types/RebalanceTypes.sol";
import "./error/IError.sol";
import "./ILedgerEvent.sol";

// Defines the error, event and ABI.
// Data should be stored in LedgerDataLayout, NOT in this contract.
interface ILedger is IError, ILedgerEvent {
    function initialize() external;

    // Functions called by cross chain manager on Ledger side
    function accountDeposit(AccountTypes.AccountDeposit calldata data) external;
    function accountDepositSol(AccountTypes.AccountDepositSol calldata data) external;
    function accountWithDrawFinish(AccountTypes.AccountWithdraw calldata withdraw) external;
    // Called by admin to revert failed withdraw
    function accountWithdrawFail(AccountTypes.AccountWithdraw calldata withdraw) external;

    // Functions called by operator manager to executre actions
    function executeProcessValidatedFutures(PerpTypes.FuturesTradeUpload calldata trade) external;
    function executeProcessValidatedFuturesV3(PerpTypes.FuturesTradeUploadV3 calldata trade) external;
    function executeProcessValidatedFuturesV4(PerpTypes.FuturesTradeUploadV4 calldata trade) external;
    function executeProcessValidatedFuturesBatch(PerpTypes.FuturesTradeUpload[] calldata trades) external;
    function executeWithdrawAction(EventTypes.WithdrawData calldata withdraw, uint64 eventId) external;
    function executeWithdrawSolAction(EventTypes.WithdrawDataSol calldata withdraw, uint64 eventId) external;
    function executeSettlement(EventTypes.Settlement calldata ledger, uint64 eventId) external;
    function executeLiquidation(EventTypes.Liquidation calldata liquidation, uint64 eventId) external;
    function executeLiquidationV2(EventTypes.LiquidationV2 calldata liquidation, uint64 eventId) external;
    function executeAdl(EventTypes.Adl calldata adl, uint64 eventId) external;
    function executeAdlV2(EventTypes.AdlV2 calldata adl, uint64 eventId) external;
    function executeFeeDistribution(EventTypes.FeeDistribution calldata feeDistribution, uint64 eventId) external;
    function executeDelegateSigner(EventTypes.DelegateSigner calldata delegateSigner, uint64 eventId) external;
    function executeDelegateWithdrawAction(EventTypes.WithdrawData calldata delegateWithdraw, uint64 eventId) external;
    function executeRebalanceBurn(RebalanceTypes.RebalanceBurnUploadData calldata data) external;
    function rebalanceBurnFinish(RebalanceTypes.RebalanceBurnCCFinishData calldata data) external;
    function executeRebalanceMint(RebalanceTypes.RebalanceMintUploadData calldata data) external;
    function rebalanceMintFinish(RebalanceTypes.RebalanceMintCCFinishData calldata data) external;
    function executeWithdraw2Contract(EventTypes.Withdraw2Contract calldata data, uint64 eventId) external;
    function executeBalanceTransfer(EventTypes.BalanceTransfer calldata balanceTransfer, uint64 eventId) external;
    function executeSwapResultUpload(EventTypes.SwapResult calldata swapResultUpload, uint64 eventId) external;
    function executeWithdraw2ContractV2(EventTypes.Withdraw2ContractV2 calldata data, uint64 eventId) external;
    function executeSettlementV3(EventTypes.SettlementV3 calldata isoSettlement, uint64 eventId) external;
    function executeAdlV3(EventTypes.AdlV3 calldata isoAdl, uint64 eventId) external;
    function executeLiquidationV3(EventTypes.LiquidationV3 calldata isoLiquidation, uint64 eventId) external;
    function executeMarginTransferV3(EventTypes.MarginTransferV3 calldata isoMarginTransfer, uint64 eventId) external;

    // view call (implemented via delegatecall to LedgerImplView)
    function getFrozenWithdrawNonce(bytes32 accountId, uint64 withdrawNonce, bytes32 tokenHash)
        external
        returns (uint128);
    // omni view call
    function batchGetUserLedger(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        external
        returns (AccountTypes.AccountSnapshot[] memory);
    function batchGetUserLedger(bytes32[] calldata accountIds)
        external
        returns (AccountTypes.AccountSnapshot[] memory);
    function batchGetUserLedgerV3(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        external
        returns (AccountTypes.AccountSnapshotV3[] memory);
    function batchGetUserLedgerV3(bytes32[] calldata accountIds)
        external
        returns (AccountTypes.AccountSnapshotV3[] memory accountSnapshots);
    function getUserTokenBalance(bytes32 accountId, bytes32 tokenHash) external returns (int128);
    function batchGetUserBalance(bytes32[] calldata accountIds)
        external
        returns (AccountTypes.AccountBalanceSnapshot[] memory);
    function getUserEscrowBalance(bytes32 accountId, bytes32 tokenHash) external returns (uint128);
    function getUserTotalFrozenBalance(bytes32 accountId, bytes32 tokenHash) external returns (uint128);
    function getBalanceTransferState(uint256 transferId)
        external
        returns (EventTypes.InternalTransferTrack memory);
    

    // admin call
    function setOperatorManagerAddress(address _operatorManagerAddress) external;
    function setCrossChainManager(address _crossChainManagerAddress) external;
    function setCrossChainManagerV2(address _crossChainManagerV2Address) external;
    function setVaultManager(address _vaultManagerAddress) external;
    function setMarketManager(address _marketManagerAddress) external;
    function setFeeManager(address _feeManagerAddress) external;
    function setLedgerImplA(address _ledgerImplA) external;
    function setLedgerImplB(address _ledgerImplB) external;
    function setLedgerImplC(address _ledgerImplC) external;
    function setLedgerImplD(address _ledgerImplD) external;
    function setLedgerImplView(address _ledgerImplView) external;
    
    /// @notice Initiates cross-chain broker status modification to multiple vault chains
    /// @dev Only callable by owner, triggers cross-contract calls to VaultManager and LedgerCrossChainManager
    /// @param chainIds Array of destination chain IDs where broker status should be modified
    /// @param brokerHash The hash identifier of the broker
    /// @param allowed Boolean indicating whether to allow or disallow the broker
    /// @param setBrokerIndex Boolean indicating whether to set the broker index for Solana chain
    /// @param brokerIndex The index to assign to the broker (used for Solana chain)
    function setBrokerFromLedger(
        uint256[] calldata chainIds, 
        bytes32 brokerHash, 
        bool allowed,
        bool setBrokerIndex,
        uint16 brokerIndex
    ) external;
}
