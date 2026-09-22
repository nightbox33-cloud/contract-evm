// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import "./dataLayout/LedgerDataLayout.sol";
import "./interface/ILedgerImplD.sol";
import "./interface/ILedgerCrossChainManager.sol";
import "./interface/ILedgerCrossChainManagerV2.sol";
import "./library/Utils.sol";
import "./library/typesHelper/AccountTypeHelper.sol";
import "./library/typesHelper/SafeCastHelper.sol";
import "./library/typesHelper/AccountTypePositionHelper.sol";

/// @title Ledger contract, implementation part D contract, for resolve EIP170 limit
/// @notice This contract is designed for contract withdraw
/// @author Orderly_Zibin
contract LedgerImplD is ILedgerImplD, OwnableUpgradeable, LedgerDataLayout {

    using AccountTypePositionHelper for AccountTypes.PerpPosition;
    using AccountTypePositionHelper for AccountTypes.IsoPerpPosition;
    using SafeCastHelper for *;
    using AccountTypeHelper for AccountTypes.Account;
    using SafeCast for uint256;
    using SafeCastHelper for uint128;

    constructor() {
        _disableInitializers();
    }

    function executeWithdraw2Contract(EventTypes.Withdraw2Contract calldata withdraw, uint64 eventId) external override{
        _executeWithdraw2EVM(withdraw, eventId);
    }

    function executeWithdraw2ContractV2(EventTypes.Withdraw2ContractV2 calldata withdrawV2, uint64 eventId) external override{
        if (withdrawV2.receiverChainType == EventTypes.ChainType.EVM) {
            _executeWithdraw2EVM(_convertV2ToEvmWithdraw(withdrawV2), eventId);
            return;
        }

        if (withdrawV2.receiverChainType == EventTypes.ChainType.SOL) {
            _executeWithdraw2SOL(withdrawV2, eventId);
            return;
        }
        revert UnsupportChainType();
    }

    function executeSwapResultUpload(EventTypes.SwapResult calldata swapResultUpload, uint64 eventId) external override {
        AccountTypes.Account storage userAccount = userLedger[swapResultUpload.accountId];
        userAccount.applyDelta(
            swapResultUpload.buyTokenHash,
            swapResultUpload.buyQuantity
        );
        userAccount.applyDelta(
            swapResultUpload.sellTokenHash,
            swapResultUpload.sellQuantity
        );
        userAccount.lastEngineEventId = eventId;

        // if on-chain success, update the balance on the vault contract
        if (swapResultUpload.swapStatus == 1) {
            vaultManager.applyDeltaBalance(
                swapResultUpload.buyTokenHash,
                swapResultUpload.chainId,
                swapResultUpload.buyQuantity
            );
            vaultManager.applyDeltaBalance(
                swapResultUpload.sellTokenHash,
                swapResultUpload.chainId,
                swapResultUpload.sellQuantity
            );
        }

        emit SwapResultUploaded(
            _newGlobalEventId(),
            swapResultUpload.accountId,
            swapResultUpload.buyTokenHash,
            swapResultUpload.sellTokenHash,
            swapResultUpload.buyQuantity,
            swapResultUpload.sellQuantity,
            swapResultUpload.chainId,
            swapResultUpload.swapStatus
        );
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL CORE
    //////////////////////////////////////////////////////////////*/

    function _executeWithdraw2EVM(EventTypes.Withdraw2Contract memory withdraw, uint64 eventId) internal {

        _checkTokenAndBroker(
            withdraw.tokenHash,
            withdraw.brokerHash,
            withdraw.chainId
        );

        _validateEvmReceiver(withdraw);

        AccountTypes.Account storage account =
            userLedger[withdraw.accountId];

        uint8 state = _checkWithdrawState(
            account,
            withdraw.accountId,
            withdraw.tokenHash,
            withdraw.chainId,
            withdraw.tokenAmount,
            withdraw.fee,
            withdraw.withdrawNonce
        );

        if (state != 0) {
            emit AccountWithdrawFail(
                withdraw.accountId,
                withdraw.withdrawNonce,
                _newGlobalEventId(),
                withdraw.brokerHash,
                withdraw.sender,
                withdraw.receiver,
                withdraw.chainId,
                withdraw.tokenHash,
                withdraw.tokenAmount,
                withdraw.fee,
                state
            );
            return;
        }

        _freezeWithdraw(
            account,
            withdraw.tokenHash,
            withdraw.chainId,
            withdraw.tokenAmount,
            withdraw.fee,
            withdraw.withdrawNonce
        );

        account.lastEngineEventId = eventId;

        emit AccountWithdrawApprove(
            withdraw.accountId,
            withdraw.withdrawNonce,
            _newGlobalEventId(),
            withdraw.brokerHash,
            withdraw.sender,
            withdraw.receiver,
            withdraw.chainId,
            withdraw.tokenHash,
            withdraw.tokenAmount,
            withdraw.fee
        );

        ILedgerCrossChainManager(crossChainManagerAddress).withdraw2Contract(withdraw);
    }
    
    function _executeWithdraw2SOL(EventTypes.Withdraw2ContractV2 memory withdraw, uint64 eventId) internal {
        
        _checkTokenAndBroker(
            withdraw.tokenHash,
            withdraw.brokerHash,
            withdraw.chainId
        );

        _validateSolReceiver(withdraw);

        AccountTypes.Account storage account =
            userLedger[withdraw.accountId];

        uint8 state = _checkWithdrawState(
            account,
            withdraw.accountId,
            withdraw.tokenHash,
            withdraw.chainId,
            withdraw.tokenAmount,
            withdraw.fee,
            withdraw.withdrawNonce
        );

        if (state != 0) {
            emit AccountWithdrawSolFail(
                withdraw.accountId,
                withdraw.withdrawNonce,
                _newGlobalEventId(),
                withdraw.senderChainType,
                withdraw.receiverChainType,
                withdraw.brokerHash,
                withdraw.sender,
                withdraw.receiver,
                withdraw.chainId,
                withdraw.tokenHash,
                withdraw.tokenAmount,
                withdraw.fee,
                state
            );
            return;
        }

        _freezeWithdraw(
            account,
            withdraw.tokenHash,
            withdraw.chainId,
            withdraw.tokenAmount,
            withdraw.fee,
            withdraw.withdrawNonce
        );

        // SOL: no async finish callback
        _finishWithdrawImmediately(
            account,
            withdraw.tokenHash,
            withdraw.chainId,
            withdraw.tokenAmount,
            withdraw.fee,
            withdraw.withdrawNonce
        );

        account.lastEngineEventId = eventId;

        emit AccountWithdrawSolApprove(
            withdraw.accountId,
            withdraw.withdrawNonce,
            _newGlobalEventId(),
            withdraw.senderChainType,
            withdraw.receiverChainType,
            withdraw.brokerHash,
            withdraw.sender,
            withdraw.receiver,
            withdraw.chainId,
            withdraw.tokenHash,
            withdraw.tokenAmount,
            withdraw.fee
        );

        ILedgerCrossChainManagerV2(crossChainManagerV2Address).withdraw2ContractV2(withdraw);
    }

    /*//////////////////////////////////////////////////////////////
                            VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _validateEvmReceiver(EventTypes.Withdraw2Contract memory withdraw) internal view {
        if (withdraw.receiver == address(0)) {
            revert WithdrawToAddressZero();
        }

        if (withdraw.vaultType == EventTypes.VaultEnum.Ceffu) {
            if (withdraw.receiver != idToPrimeWallet[withdraw.accountId]) revert InvalidPrimeWallet();
            return;
        }

        if (withdraw.vaultType == EventTypes.VaultEnum.ProtocolVault) {
            if (!Utils.validateExtendedAccountId(
                    withdraw.receiver,
                    withdraw.accountId,
                    withdraw.brokerHash,
                    withdraw.sender
                )
            ) revert AccountIdInvalid();

            if (!isValidVault[withdraw.receiver]) {
                revert InvalidVault();
            }
            return;
        }

        revert NotImplemented();
    }

    function _validateSolReceiver(EventTypes.Withdraw2ContractV2 memory withdraw) internal view {
        if (withdraw.receiver == bytes32(0)) {
            revert WithdrawToAddressZero();
        }

        // Only Ceffu vault type is supported for Solana withdrawals
        if ( withdraw.vaultType == EventTypes.VaultEnum.Ceffu) {
            if ( withdraw.receiver != idToSolanaPrimeWallet[withdraw.accountId]) revert InvalidPrimeWallet();
            return;
        }

        revert NotImplemented(); 
    }

    function _checkWithdrawState(
        AccountTypes.Account storage account,
        bytes32 accountId,
        bytes32 tokenHash,
        uint256 chainId,
        uint128 tokenAmount,
        uint128 fee,
        uint64 withdrawNonce
    ) internal view returns (uint8) {
        if (account.lastWithdrawNonce >= withdrawNonce) {
            return 101;
        }

        int128 balance = account.balances[tokenHash];
        if (balance < tokenAmount.toInt128()) {
            revert WithdrawBalanceNotEnough(balance, tokenAmount);
        }

        int128 available = balance - escrowBalances[accountId][tokenHash].toInt128();
        /// @dev Check available balance (balance - escrow) to prevent withdrawal of in-flight transfer funds
        if (available < tokenAmount.toInt128()) {
            return 9;
        }

        uint128 vaultBalance = vaultManager.getBalance(tokenHash, chainId);
        if (vaultBalance < tokenAmount - fee) {
            revert WithdrawVaultBalanceNotEnough(vaultBalance, tokenAmount - fee);
        }

        uint128 maxFee = vaultManager.getMaxWithdrawFee(tokenHash);
        if (maxFee > 0 && fee > maxFee) revert WithdrawFeeTooLarge(maxFee, fee);
    
        return 0;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE UPDATE
    //////////////////////////////////////////////////////////////*/

    function _freezeWithdraw(
        AccountTypes.Account storage account,
        bytes32 tokenHash,
        uint256 chainId,
        uint128 tokenAmount,
        uint128 fee,
        uint64 withdrawNonce
    ) internal {
        account.frozenBalance(
            withdrawNonce,
            tokenHash,
            tokenAmount
        );

        vaultManager.frozenBalance(
            tokenHash,
            chainId,
            tokenAmount - fee
        );
    }

    function _finishWithdrawImmediately(
        AccountTypes.Account storage account,
        bytes32 tokenHash,
        uint256 chainId,
        uint128 tokenAmount,
        uint128 fee,
        uint64 withdrawNonce
    ) internal {
        account.finishFrozenBalance(
            withdrawNonce,
            tokenHash,
            tokenAmount
        );

        vaultManager.finishFrozenBalance(
            tokenHash,
            chainId,
            tokenAmount - fee
        );

        if (fee > 0) {
            bytes32 feeCollectorId = feeManager.getFeeCollector(IFeeManager.FeeCollectorType.WithdrawFeeCollector);
            userLedger[feeCollectorId].addBalance(tokenHash, fee);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    function _convertV2ToEvmWithdraw(EventTypes.Withdraw2ContractV2 memory v2) internal pure returns (EventTypes.Withdraw2Contract memory) {
        return EventTypes.Withdraw2Contract({
            tokenAmount: v2.tokenAmount,
            fee: v2.fee,
            chainId: v2.chainId,
            accountId: v2.accountId,
            vaultType: v2.vaultType,
            sender: Utils.bytes32ToAddress(v2.sender),
            withdrawNonce: v2.withdrawNonce,
            receiver: Utils.bytes32ToAddress(v2.receiver),
            timestamp: v2.timestamp,
            brokerHash: v2.brokerHash,
            tokenHash: v2.tokenHash,
            clientId: v2.clientId
        });
    }

    function _checkTokenAndBroker(bytes32 tokenHash, bytes32 brokerHash, uint256 chainId) internal view {
        if (!vaultManager.getAllowedBroker(brokerHash)) revert BrokerNotAllowed();
        if (!vaultManager.getAllowedChainToken(tokenHash, chainId)) revert TokenNotAllowed(tokenHash, chainId);
    }

    function _newGlobalEventId() internal returns (uint64) {
        return ++globalEventId;
    }

    /*//////////////////////////////////////////////////////////////
                Isolated Margin & Cross Margin Logic
    //////////////////////////////////////////////////////////////*/

    function executeProcessValidatedFuturesV3(PerpTypes.FuturesTradeUploadV3 calldata isoTrade) external override {
        // validate data first
        if (!vaultManager.getAllowedSymbol(isoTrade.symbolHash)) revert SymbolNotAllowed();
        // do the logic part
        AccountTypes.Account storage account = userLedger[isoTrade.accountId];
        
        if (isoTrade.marginMode == 0) {
            // cross position trade upload
            AccountTypes.PerpPosition storage position = account.perpPositions[isoTrade.symbolHash];
            // convert to normal futures trade upload
            PerpTypes.FuturesTradeUpload memory trade = PerpTypes.FuturesTradeUpload({
                accountId: isoTrade.accountId,
                symbolHash: isoTrade.symbolHash,
                feeAssetHash: isoTrade.feeAssetHash,
                tradeQty: isoTrade.tradeQty,
                notional: isoTrade.notional,
                executedPrice: isoTrade.executedPrice,
                fee: isoTrade.fee,
                sumUnitaryFundings: isoTrade.sumUnitaryFundings,
                tradeId: isoTrade.tradeId,
                matchId: isoTrade.matchId,
                timestamp: isoTrade.timestamp,
                side: isoTrade.side
            });
            _processPosition(position, trade);
            
        } else if (isoTrade.marginMode == 1) { 
            // Iso Position Trade Upload
            AccountTypes.IsoPerpPosition storage isoPosition = account.isoPerpPositions[isoTrade.symbolHash];
            _processIsoPosition(isoPosition, isoTrade);

            // update iso margin if position margin changed
            // If marginFromCross > 0, it means margin is transferred from cross to isolated
            // If marginFromCross < 0, it means margin is transferred from isolated to cross, it will be finished in MarginTransferV3, skip processing here
            // This is a biz logic, intentionally not processing marginFromCross < 0 here
            if (isoTrade.marginFromCross > 0) {
                account.balances[isoTrade.isoMarginAssetHash] -= isoTrade.marginFromCross;
                isoPosition.margins[isoTrade.isoMarginAssetHash] += isoTrade.marginFromCross;
            }

        }

        account.lastPerpTradeId = isoTrade.tradeId;
        // update last funding update timestamp
        marketManager.setLastFundingUpdated(isoTrade.symbolHash, isoTrade.timestamp);

        emit ProcessValidatedFuturesV3(
            isoTrade.accountId,
            isoTrade.symbolHash,
            isoTrade.feeAssetHash,
            isoTrade.tradeQty,
            isoTrade.notional,
            isoTrade.executedPrice,
            isoTrade.fee,
            isoTrade.sumUnitaryFundings,
            isoTrade.tradeId,
            isoTrade.matchId,
            // isoTrade.timestamp,
            isoTrade.side,
            isoTrade.marginMode,
            isoTrade.isoMarginAssetHash,
            isoTrade.marginFromCross
        );
    }

    /// @notice V4 trade upload. Same state transition as `executeProcessValidatedFuturesV3`, except that when
    ///         `trade.isInsuranceAccount` is true the averageEntryPrice / openingCost recomputation is skipped.
    /// @dev isInsuranceAccount == false: byte-for-byte the same logic as V3.
    ///      isInsuranceAccount == true : funding, positionQty, costPosition, lastExecutedPrice, fee collector,
    ///      lastPerpTradeId and isolated margin transfer are still updated; only avg entry price / opening cost
    ///      keep their previous values.
    function executeProcessValidatedFuturesV4(PerpTypes.FuturesTradeUploadV4 calldata trade) external override {
        // validate data first
        if (!vaultManager.getAllowedSymbol(trade.symbolHash)) revert SymbolNotAllowed();
        // do the logic part
        AccountTypes.Account storage account = userLedger[trade.accountId];

        if (trade.marginMode == 0) {
            // cross position trade upload
            AccountTypes.PerpPosition storage position = account.perpPositions[trade.symbolHash];
            _processPositionV4(position, trade);
        } else if (trade.marginMode == 1) {
            // Iso Position Trade Upload
            AccountTypes.IsoPerpPosition storage isoPosition = account.isoPerpPositions[trade.symbolHash];
            _processIsoPositionV4(isoPosition, trade);

            // update iso margin if position margin changed
            // If marginFromCross > 0, it means margin is transferred from cross to isolated
            // If marginFromCross < 0, it means margin is transferred from isolated to cross, it will be finished in MarginTransferV3, skip processing here
            // This is a biz logic, intentionally not processing marginFromCross < 0 here
            if (trade.marginFromCross > 0) {
                account.balances[trade.isoMarginAssetHash] -= trade.marginFromCross;
                isoPosition.margins[trade.isoMarginAssetHash] += trade.marginFromCross;
            }
        }

        account.lastPerpTradeId = trade.tradeId;
        // update last funding update timestamp
        marketManager.setLastFundingUpdated(trade.symbolHash, trade.timestamp);

        _emitProcessValidatedFuturesV4(trade);
    }

    function executeSettlementV3(EventTypes.SettlementV3 calldata settlementV3, uint64 eventId) external override {
        AccountTypes.Account storage account = userLedger[settlementV3.accountId];

        // Note: Insurance transfer amount should always be zero, for both cross-margin and isolated-margin mode.
        if (settlementV3.insuranceTransferAmount != 0) {
            revert InsuranceTransferAmountInvalid(  
                userLedger[settlementV3.accountId].balances[settlementV3.settledAssetHash],
                settlementV3.insuranceTransferAmount,
                settlementV3.settledAmount
            );
        }

        int128 totalSettleAmount = 0;
        // gas saving
        uint256 length = settlementV3.isoSettlementExecutions.length;

        EventTypes.SettlementExecutionV3[] calldata isoSettlementExecutions = settlementV3.isoSettlementExecutions;

        for (uint256 i = 0; i < length; ++i) {
            EventTypes.SettlementExecutionV3 calldata ledgerExecution = isoSettlementExecutions[i];
            totalSettleAmount += ledgerExecution.settledAmount;
            if (!vaultManager.getAllowedSymbol(ledgerExecution.symbolHash)) revert SymbolNotAllowed();
            if (ledgerExecution.marginMode == 0) {
                AccountTypes.PerpPosition storage position = account.perpPositions[ledgerExecution.symbolHash];
                position.chargeFundingFee(ledgerExecution.sumUnitaryFundings);
                position.costPosition += ledgerExecution.settledAmount;
                position.lastExecutedPrice = ledgerExecution.markPrice;
                position.lastSettledPrice = ledgerExecution.markPrice;

                // Update cross-margin balance
                account.balances[settlementV3.settledAssetHash] += ledgerExecution.settledAmount;

                if (position.isFullSettled()) {
                    delete account.perpPositions[ledgerExecution.symbolHash];
                }
            } else if (ledgerExecution.marginMode == 1) {
                AccountTypes.IsoPerpPosition storage isoPosition = account.isoPerpPositions[ledgerExecution.symbolHash];
                isoPosition.chargeFundingFee(ledgerExecution.sumUnitaryFundings);
                isoPosition.costPosition += ledgerExecution.settledAmount;
                isoPosition.lastExecutedPrice = ledgerExecution.markPrice;
                isoPosition.lastSettledPrice = ledgerExecution.markPrice;

                // FIXED: Update the isolated margin for the correct position using multi-collateral mapping
                // symbolHash identifies the position, isoMarginAssetHash identifies which collateral
                isoPosition.margins[ledgerExecution.isoMarginAssetHash] += ledgerExecution.settledAmount;

            } else {
                revert InvalidMarginMode(ledgerExecution.marginMode);
            }

            emit SettlementExecutionV3(
                ledgerExecution.symbolHash,
                ledgerExecution.markPrice,
                ledgerExecution.sumUnitaryFundings,
                ledgerExecution.settledAmount,
                ledgerExecution.marginMode,
                ledgerExecution.isoMarginAssetHash
            );
        }
        if (totalSettleAmount != settlementV3.settledAmount) revert TotalSettleAmountNotMatch(totalSettleAmount);
        account.lastEngineEventId = eventId;
        // emit event
        emit SettlementResultV3(
            _newGlobalEventId(),
            settlementV3.accountId,
            settlementV3.settledAmount,
            settlementV3.settledAssetHash,
            settlementV3.insuranceAccountId,
            settlementV3.insuranceTransferAmount,
            uint64(length),
            eventId
        );

    }

    function executeAdlV3(EventTypes.AdlV3 calldata adlV3, uint64 eventId) external override {
        if (!vaultManager.getAllowedSymbol(adlV3.symbolHash)) revert SymbolNotAllowed();
        AccountTypes.Account storage account = userLedger[adlV3.accountId];

        if (adlV3.marginMode == 0) {
            // cross position adl
            AccountTypes.PerpPosition storage position = account.perpPositions[adlV3.symbolHash];

            int128 tmpUserPositionQty = position.positionQty; // gas saving
            if (tmpUserPositionQty == 0) revert UserPerpPositionQtyZero(adlV3.accountId, adlV3.symbolHash);
            if (adlV3.positionQtyTransfer.abs() > tmpUserPositionQty.abs()) {
                revert InsurancePositionQtyInvalid(adlV3.positionQtyTransfer, tmpUserPositionQty);
            }

            position.chargeFundingFee(adlV3.sumUnitaryFundings);
            if (!adlV3.isInsuranceAccount) {
                position.calAverageEntryPrice(adlV3.positionQtyTransfer, adlV3.adlPrice.toInt128(), -adlV3.costPositionTransfer);
            }
            position.positionQty += adlV3.positionQtyTransfer;
            position.costPosition += adlV3.costPositionTransfer;
            position.lastExecutedPrice = adlV3.adlPrice;
            position.lastAdlPrice = adlV3.adlPrice;

        } else if (adlV3.marginMode == 1) {
            // Iso Position Adl
            AccountTypes.IsoPerpPosition storage isoPosition = account.isoPerpPositions[adlV3.symbolHash];

            int128 tmpUserPositionQty = isoPosition.positionQty; // gas saving
            if (tmpUserPositionQty == 0) revert UserPerpPositionQtyZero(adlV3.accountId, adlV3.symbolHash);
            if (adlV3.positionQtyTransfer.abs() > tmpUserPositionQty.abs()) {
                revert InsurancePositionQtyInvalid(adlV3.positionQtyTransfer, tmpUserPositionQty);
            }

            isoPosition.chargeFundingFee(adlV3.sumUnitaryFundings);
            if (!adlV3.isInsuranceAccount) {
                isoPosition.calAverageEntryPrice(adlV3.positionQtyTransfer, adlV3.adlPrice.toInt128(), -adlV3.costPositionTransfer);
            }
            isoPosition.positionQty += adlV3.positionQtyTransfer;
            isoPosition.costPosition += adlV3.costPositionTransfer;
            isoPosition.lastExecutedPrice = adlV3.adlPrice;
            isoPosition.lastAdlPrice = adlV3.adlPrice;

            // FIXED: Handle margin transfer (supports both positive and negative)
            // Positive: release margin from isolated to cross
            // Negative: add margin from cross to isolated (rare but possible)
            if (adlV3.marginToCross > 0) {
                account.balances[adlV3.isoMarginAssetHash] += adlV3.marginToCross;
                isoPosition.margins[adlV3.isoMarginAssetHash] -= adlV3.marginToCross;
            } else if (adlV3.marginToCross < 0) {
                revert IsoAdlMarginToCrossAmountInvalid(adlV3.marginToCross);
            }
        } else {
            revert InvalidMarginMode(adlV3.marginMode);
        }

        account.lastEngineEventId = eventId;

        emit AdlResultV3(
            _newGlobalEventId(),
            adlV3.accountId,
            adlV3.isInsuranceAccount,
            adlV3.symbolHash,
            adlV3.positionQtyTransfer,
            adlV3.costPositionTransfer,
            adlV3.adlPrice,
            adlV3.sumUnitaryFundings,
            adlV3.marginMode,
            adlV3.isoMarginAssetHash,
            adlV3.marginToCross,
            eventId
        );
    }

    function executeLiquidationV3(EventTypes.LiquidationV3 calldata liquidationV3, uint64 eventId) external override {
        AccountTypes.Account storage account = userLedger[liquidationV3.accountId];

        // check the margin mode of the liquidation transfers, if there are multiple transfers, they should be all cross or all iso, cannot mix
        // if there is only one transfer, use its margin mode as the liquidation margin mode
        // if there are multiple transfers, use cross margin as default, and validate all transfers are cross margin, if not, revert
        uint8 marginMode = 0;
        if (liquidationV3.liquidationTransfers.length == 1 && liquidationV3.liquidationTransfers[0].marginMode == 1) {
            // iso
            marginMode = 1;
        } else if (liquidationV3.liquidationTransfers.length > 1) {
                for (uint256 i = 0; i < liquidationV3.liquidationTransfers.length; i++) {
                    require(liquidationV3.liquidationTransfers[i].marginMode == 0, "Invalid margin mode for multiple liquidation transfers");
                }
        } 

        if (marginMode == 0) {
            // cross
            if (liquidationV3.insuranceTransferAmount != 0) {
                uint128 absoluteAmt = liquidationV3.insuranceTransferAmount.abs();
                if (liquidationV3.insuranceTransferAmount > 0) {
                    account.addBalance(liquidationV3.liquidatedAssetHash, absoluteAmt);
                } else {
                    account.subBalance(liquidationV3.liquidatedAssetHash, absoluteAmt);
                }
            }
        } else if (marginMode == 1) {
            // iso
            AccountTypes.IsoPerpPosition storage isoPosition = account.isoPerpPositions[liquidationV3.liquidationTransfers[0].symbolHash];
            if (liquidationV3.insuranceTransferAmount != 0) {
                isoPosition.margins[liquidationV3.liquidatedAssetHash] += liquidationV3.insuranceTransferAmount;
            }
        } else {
            revert InvalidMarginMode(marginMode);
        }

        uint256 length = liquidationV3.liquidationTransfers.length;
        for (uint256 i = 0; i < length; i++) {
            EventTypes.LiquidationTransferV3 calldata liquidationTransferV3 = liquidationV3.liquidationTransfers[i];

            // FIXED Issue #5: Add symbol validation
            if (!vaultManager.getAllowedSymbol(liquidationTransferV3.symbolHash)) revert SymbolNotAllowed();

            _liquidationLiquidateV3(account, liquidationTransferV3, !liquidationV3.isInsuranceAccount);
            emit LiquidationTransferV3(
                liquidationV3.accountId,
                liquidationTransferV3.symbolHash,
                liquidationTransferV3.positionQtyTransfer,
                liquidationTransferV3.costPositionTransfer,
                liquidationTransferV3.fee,
                liquidationTransferV3.markPrice,
                liquidationTransferV3.sumUnitaryFundings,
                liquidationTransferV3.marginMode,
                liquidationTransferV3.isoMarginAssetHash,
                liquidationTransferV3.marginToCross
            );
        }
        account.lastEngineEventId = eventId;
        // emit event
        emit LiquidationResultV3(
            _newGlobalEventId(),
            liquidationV3.accountId,
            liquidationV3.liquidatedAssetHash,
            liquidationV3.insuranceTransferAmount,
            liquidationV3.isInsuranceAccount,
            eventId
        );
    }

    function executeMarginTransferV3(EventTypes.MarginTransferV3 calldata isoMarginTransfer, uint64 eventId) external override {
        AccountTypes.Account storage account = userLedger[isoMarginTransfer.accountId];
        AccountTypes.IsoPerpPosition storage isoPosition = account.isoPerpPositions[isoMarginTransfer.isoSymbolHash];

        // Execute the transfer using multi-collateral margin mapping
        account.balances[isoMarginTransfer.transferAssetHash] -= isoMarginTransfer.marginFromCross;
        isoPosition.margins[isoMarginTransfer.transferAssetHash] += isoMarginTransfer.marginFromCross;

        account.lastEngineEventId = eventId;

        emit MarginTransferV3(
            _newGlobalEventId(),
            isoMarginTransfer.accountId,
            isoMarginTransfer.marginFromCross,
            isoMarginTransfer.transferAssetHash,
            isoMarginTransfer.isoSymbolHash,
            isoMarginTransfer.timestamp,
            eventId
        );
    }

    // =================== internal =================== //

    function _processPosition(AccountTypes.PerpPosition storage position, PerpTypes.FuturesTradeUpload memory trade) internal {
        position.chargeFundingFee(trade.sumUnitaryFundings);
        if (!calAvgSkipList[trade.accountId]) {
            position.calAverageEntryPrice(trade.tradeQty, trade.executedPrice.toInt128(), 0);
        } else {
            (bool ok, uint128 avg, int128 oc) = AccountTypePositionHelper.tryCalAverageEntryPrice(
                position.positionQty, position.openingCost, trade.tradeQty, trade.executedPrice.toInt128(), 0
            );
            if (ok) {
                position.averageEntryPrice = avg;
                position.openingCost = oc;
            } else {
                emit CalAverageEntryPriceSkipped(
                    trade.accountId, trade.symbolHash, trade.tradeId,
                    position.positionQty, trade.tradeQty, position.openingCost
                );
            }
        }
        position.positionQty += trade.tradeQty;
        position.costPosition += trade.notional;
        position.lastExecutedPrice = trade.executedPrice;
        // fee_swap_position
        _feeSwapPosition(position, trade.symbolHash, trade.fee, trade.tradeId, trade.sumUnitaryFundings);
        
    }

    function _processIsoPosition(AccountTypes.IsoPerpPosition storage isoPosition, PerpTypes.FuturesTradeUploadV3 calldata isoTrade) internal {
        isoPosition.chargeFundingFee(isoTrade.sumUnitaryFundings);
        if (!calAvgSkipList[isoTrade.accountId]) {
            isoPosition.calAverageEntryPrice(isoTrade.tradeQty, isoTrade.executedPrice.toInt128(), 0);
        } else {
            (bool ok, uint128 avg, int128 oc) = AccountTypePositionHelper.tryCalAverageEntryPrice(
                isoPosition.positionQty, isoPosition.openingCost, isoTrade.tradeQty, isoTrade.executedPrice.toInt128(), 0
            );
            if (ok) {
                isoPosition.averageEntryPrice = avg;
                isoPosition.openingCost = oc;
            } else {
                emit CalAverageEntryPriceSkipped(
                    isoTrade.accountId, isoTrade.symbolHash, isoTrade.tradeId,
                    isoPosition.positionQty, isoTrade.tradeQty, isoPosition.openingCost
                );
            }
        }
        isoPosition.positionQty += isoTrade.tradeQty;
        isoPosition.costPosition += isoTrade.notional;
        isoPosition.lastExecutedPrice = isoTrade.executedPrice;
        // fee_swap_position
        _feeSwapPositionV3(isoPosition, isoTrade.symbolHash, isoTrade.fee, isoTrade.tradeId, isoTrade.sumUnitaryFundings);
    }


    function _feeSwapPosition(
        AccountTypes.PerpPosition storage position,
        bytes32 symbol,
        int128 feeAmount,
        uint64 tradeId,
        int128 sumUnitaryFundings
    ) internal {
        if (feeAmount == 0) return;
        _perpFeeCollectorDeposit(symbol, feeAmount, tradeId, sumUnitaryFundings);
        position.costPosition += feeAmount;
    }
    function _feeSwapPositionV3(
        AccountTypes.IsoPerpPosition storage isoPosition,
        bytes32 symbol,
        int128 feeAmount,
        uint64 tradeId,
        int128 sumUnitaryFundings
    ) internal {
        if (feeAmount == 0) return;
        _perpFeeCollectorDeposit(symbol, feeAmount, tradeId, sumUnitaryFundings);
        isoPosition.costPosition += feeAmount;
    }

    // ---- V4 (isInsuranceAccount aware) ----
    // Mirrors _processPosition exactly; the only difference is the guard around calAverageEntryPrice.
    function _processPositionV4(AccountTypes.PerpPosition storage position, PerpTypes.FuturesTradeUploadV4 calldata trade) internal {
        position.chargeFundingFee(trade.sumUnitaryFundings);
        if (!trade.isInsuranceAccount) {
            position.calAverageEntryPrice(trade.tradeQty, trade.executedPrice.toInt128(), 0);
        }
        position.positionQty += trade.tradeQty;
        position.costPosition += trade.notional;
        position.lastExecutedPrice = trade.executedPrice;
        // fee_swap_position
        _feeSwapPosition(position, trade.symbolHash, trade.fee, trade.tradeId, trade.sumUnitaryFundings);
    }

    // Mirrors _processIsoPosition exactly; the only difference is the guard around calAverageEntryPrice.
    function _processIsoPositionV4(AccountTypes.IsoPerpPosition storage isoPosition, PerpTypes.FuturesTradeUploadV4 calldata trade) internal {
        isoPosition.chargeFundingFee(trade.sumUnitaryFundings);
        if (!trade.isInsuranceAccount) {
            isoPosition.calAverageEntryPrice(trade.tradeQty, trade.executedPrice.toInt128(), 0);
        }
        isoPosition.positionQty += trade.tradeQty;
        isoPosition.costPosition += trade.notional;
        isoPosition.lastExecutedPrice = trade.executedPrice;
        // fee_swap_position
        _feeSwapPositionV3(isoPosition, trade.symbolHash, trade.fee, trade.tradeId, trade.sumUnitaryFundings);
    }

    // Separate function to keep the emit's stack usage away from the caller's locals (avoid stack too deep)
    function _emitProcessValidatedFuturesV4(PerpTypes.FuturesTradeUploadV4 calldata trade) internal {
        emit ProcessValidatedFuturesV4(
            trade.accountId,
            trade.symbolHash,
            trade.feeAssetHash,
            trade.tradeQty,
            trade.notional,
            trade.executedPrice,
            trade.fee,
            trade.sumUnitaryFundings,
            trade.tradeId,
            trade.matchId,
            // trade.timestamp,
            trade.side,
            trade.marginMode,
            trade.isoMarginAssetHash,
            trade.marginFromCross,
            trade.isInsuranceAccount
        );
    }

    function _perpFeeCollectorDeposit(bytes32 symbol, int128 amount, uint64 tradeId, int128 sumUnitaryFundings)
        internal
    {
        bytes32 feeCollectorAccountId = feeManager.getFeeCollector(IFeeManager.FeeCollectorType.FuturesFeeCollector);
        AccountTypes.Account storage feeCollectorAccount = userLedger[feeCollectorAccountId];
        AccountTypes.PerpPosition storage feeCollectorPosition = feeCollectorAccount.perpPositions[symbol];
        feeCollectorPosition.costPosition -= amount;
        feeCollectorPosition.lastSumUnitaryFundings = sumUnitaryFundings;
        if (tradeId > feeCollectorAccount.lastPerpTradeId) {
            feeCollectorAccount.lastPerpTradeId = tradeId;
        }
    }

     function _liquidationLiquidateV2(
        AccountTypes.Account storage liquidationAccount,
        EventTypes.LiquidationTransferV2 calldata liquidationTransfer,
        bool needCalAvg
    ) internal {
        AccountTypes.PerpPosition storage liquidationPosition =
            liquidationAccount.perpPositions[liquidationTransfer.symbolHash];
        liquidationPosition.chargeFundingFee(liquidationTransfer.sumUnitaryFundings);
        if (needCalAvg) {
            liquidationPosition.calAverageEntryPrice(
                liquidationTransfer.positionQtyTransfer,
                liquidationTransfer.markPrice.toInt128(),
                -liquidationTransfer.costPositionTransfer - liquidationTransfer.fee
            );
        }
        liquidationPosition.positionQty += liquidationTransfer.positionQtyTransfer;
        liquidationPosition.costPosition += liquidationTransfer.costPositionTransfer + liquidationTransfer.fee;
        liquidationPosition.lastExecutedPrice = liquidationTransfer.markPrice;
        if (liquidationPosition.isFullSettled()) {
            delete liquidationAccount.perpPositions[liquidationTransfer.symbolHash];
        }
    }

    function _liquidationLiquidateV3(
        AccountTypes.Account storage liquidationAccount,
        EventTypes.LiquidationTransferV3 calldata liquidationTransferV3,
        bool needCalAvg
    ) internal {

        if (liquidationTransferV3.marginMode == 0) {
            // cross
            AccountTypes.PerpPosition storage liquidationPosition =
            liquidationAccount.perpPositions[liquidationTransferV3.symbolHash];
            liquidationPosition.chargeFundingFee(liquidationTransferV3.sumUnitaryFundings);
            if (needCalAvg) {
                liquidationPosition.calAverageEntryPrice(
                    liquidationTransferV3.positionQtyTransfer,
                    liquidationTransferV3.markPrice.toInt128(),
                    -liquidationTransferV3.costPositionTransfer - liquidationTransferV3.fee
                );
            }
            liquidationPosition.positionQty += liquidationTransferV3.positionQtyTransfer;
            liquidationPosition.costPosition += liquidationTransferV3.costPositionTransfer + liquidationTransferV3.fee;
            liquidationPosition.lastExecutedPrice = liquidationTransferV3.markPrice;
            if (liquidationPosition.isFullSettled()) {
                delete liquidationAccount.perpPositions[liquidationTransferV3.symbolHash];
            }
        } else if (liquidationTransferV3.marginMode == 1) {
            // iso
            AccountTypes.IsoPerpPosition storage isoLiquidationPosition =
            liquidationAccount.isoPerpPositions[liquidationTransferV3.symbolHash];
            isoLiquidationPosition.chargeFundingFee(liquidationTransferV3.sumUnitaryFundings);
            if (needCalAvg) {
                isoLiquidationPosition.calAverageEntryPrice(
                    liquidationTransferV3.positionQtyTransfer,
                    liquidationTransferV3.markPrice.toInt128(),
                    -liquidationTransferV3.costPositionTransfer - liquidationTransferV3.fee
                );
            }
            isoLiquidationPosition.positionQty += liquidationTransferV3.positionQtyTransfer;
            isoLiquidationPosition.costPosition += liquidationTransferV3.costPositionTransfer + liquidationTransferV3.fee;
            isoLiquidationPosition.lastExecutedPrice = liquidationTransferV3.markPrice;
            
            // Process marginToCross for isolated positions
            if (liquidationTransferV3.marginMode == 1 && liquidationTransferV3.marginToCross != 0) {
                liquidationAccount.balances[liquidationTransferV3.isoMarginAssetHash] += liquidationTransferV3.marginToCross;
                isoLiquidationPosition.margins[liquidationTransferV3.isoMarginAssetHash] -= liquidationTransferV3.marginToCross;
            }

        } else {
            revert InvalidMarginMode(liquidationTransferV3.marginMode);
        }



    }


}
