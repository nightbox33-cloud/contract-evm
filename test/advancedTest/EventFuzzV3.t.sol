// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "../../src/OperatorManager.sol";
import "../../src/VaultManager.sol";
import "../../src/MarketManager.sol";
import "../../src/FeeManager.sol";
import "../mock/LedgerCrossChainManagerMock.sol";
import "../cheater/LedgerCheater.sol";
import "../../src/LedgerImplA.sol";
import "../../src/LedgerImplD.sol";

contract EventFuzzV3Test is Test {
    using SafeCastHelper for *;

    bytes32 constant BROKER_HASH = 0x083098c593f395bea1de45dda552d9f14e8fcb0be3faaa7a1903c5477d7ba7fd;
    bytes32 constant TOKEN_HASH = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant SYMBOL_HASH_BTC_USDC = 0x1111101010101010101010101010101010101010101010101010101010101010;
    bytes32 constant SYMBOL_HASH_ETH_USDC = 0x2222101010101010101010101010101010101010101010101010101010101010;
    uint256 constant CHAIN_ID = 986532;
    bytes32 constant ALICE = 0xa11ce00000000000000000000000000000000000000000000000000000000000;
    bytes32 constant BOB = 0xb0b0000000000000000000000000000000000000000000000000000000000000;
    bytes32 constant INSURANCE_FUND = 0x1234123412341234123412341234123412341234123412341234123412341234;

    ProxyAdmin admin;
    address constant operatorAddress = address(0x1234567890);
    LedgerCrossChainManagerMock ledgerCrossChainManager;
    IOperatorManager operatorManager;
    IVaultManager vaultManager;
    LedgerCheater ledger;
    IFeeManager feeManager;
    IMarketManager marketManager;
    TransparentUpgradeableProxy operatorProxy;
    TransparentUpgradeableProxy vaultProxy;
    TransparentUpgradeableProxy ledgerProxy;
    TransparentUpgradeableProxy feeProxy;
    TransparentUpgradeableProxy marketProxy;

    function setUp() public {
        admin = new ProxyAdmin();

        ledgerCrossChainManager = new LedgerCrossChainManagerMock();

        IOperatorManager operatorManagerImpl = new OperatorManager();
        IVaultManager vaultManagerImpl = new VaultManager();
        ILedger ledgerImpl = new LedgerCheater();
        IFeeManager feeImpl = new FeeManager();
        IMarketManager marketImpl = new MarketManager();
        LedgerImplA ledgerImplA = new LedgerImplA();
        LedgerImplD ledgerImplD = new LedgerImplD();

        bytes memory initData = abi.encodeWithSignature("initialize()");
        operatorProxy = new TransparentUpgradeableProxy(address(operatorManagerImpl), address(admin), initData);
        vaultProxy = new TransparentUpgradeableProxy(address(vaultManagerImpl), address(admin), initData);
        ledgerProxy = new TransparentUpgradeableProxy(address(ledgerImpl), address(admin), initData);
        feeProxy = new TransparentUpgradeableProxy(address(feeImpl), address(admin), initData);
        marketProxy = new TransparentUpgradeableProxy(address(marketImpl), address(admin), initData);

        operatorManager = IOperatorManager(address(operatorProxy));
        vaultManager = IVaultManager(address(vaultProxy));
        ledger = LedgerCheater(address(ledgerProxy));
        feeManager = IFeeManager(address(feeProxy));
        marketManager = IMarketManager(address(marketProxy));

        ledger.setOperatorManagerAddress(address(operatorManager));
        ledger.setCrossChainManager(address(ledgerCrossChainManager));
        ledger.setVaultManager(address(vaultManager));
        ledger.setFeeManager(address(feeManager));
        ledger.setMarketManager(address(marketManager));
        ledger.setLedgerImplA(address(ledgerImplA));
        ledger.setLedgerImplD(address(ledgerImplD));

        operatorManager.setOperator(operatorAddress);
        operatorManager.setLedger(address(ledger));

        vaultManager.setLedgerAddress(address(ledger));
        if (!vaultManager.getAllowedToken(TOKEN_HASH)) {
            vaultManager.setAllowedToken(TOKEN_HASH, true);
        }
        if (!vaultManager.getAllowedBroker(BROKER_HASH)) {
            vaultManager.setAllowedBroker(BROKER_HASH, true);
        }
        if (!vaultManager.getAllowedSymbol(SYMBOL_HASH_BTC_USDC)) {
            vaultManager.setAllowedSymbol(SYMBOL_HASH_BTC_USDC, true);
        }
        if (!vaultManager.getAllowedSymbol(SYMBOL_HASH_ETH_USDC)) {
            vaultManager.setAllowedSymbol(SYMBOL_HASH_ETH_USDC, true);
        }
        vaultManager.setAllowedChainToken(TOKEN_HASH, CHAIN_ID, true);

        feeManager.setLedgerAddress(address(ledger));

        marketManager.setOperatorManagerAddress(address(operatorManager));
        marketManager.setLedgerAddress(address(ledger));

        ledgerCrossChainManager.setLedger(address(ledger));
        ledgerCrossChainManager.setOperatorManager(address(operatorManager));

        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(BOB, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 10_000_000_000, CHAIN_ID);
    }

    // =================== Fuzz: settlementV3 cross ===================

    function testFuzz_settlementV3_cross(int128 settleAmount, uint128 markPrice) public {
        vm.assume(settleAmount > -1_000_000_000 && settleAmount < 1_000_000_000);

        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: 1_000_000_000,
                costPosition: 100_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        int128 balanceBefore = ledger.getUserLedgerBalance(ALICE, TOKEN_HASH);

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: markPrice,
            sumUnitaryFundings: 0, // same as last, no funding fee
            settledAmount: settleAmount,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: settleAmount,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            1
        );

        // Cross balance change should equal settledAmount
        int128 balanceAfter = ledger.getUserLedgerBalance(ALICE, TOKEN_HASH);
        assertEq(balanceAfter - balanceBefore, settleAmount, "cross balance delta == settledAmount");
    }

    // =================== Fuzz: settlementV3 iso ===================

    function testFuzz_settlementV3_iso(int128 settleAmount) public {
        vm.assume(settleAmount > -500_000_000 && settleAmount < 500_000_000);

        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_ETH_USDC, 1_000_000_000, 100_000_000, 0, 20_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 500_000_000);

        int128 isoMarginBefore = ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH);

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: settleAmount,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: settleAmount,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            2
        );

        // Iso margin change should equal settledAmount
        int128 isoMarginAfter = ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH);
        assertEq(isoMarginAfter - isoMarginBefore, settleAmount, "iso margin delta == settledAmount");
        // Cross balance unchanged
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000, "cross balance unchanged for iso settlement");
    }

    // =================== Fuzz: marginTransferV3 ===================

    function testFuzz_marginTransferV3(int128 marginFromCross) public {
        vm.assume(marginFromCross > -500_000_000 && marginFromCross < 500_000_000);

        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 500_000_000, 50_000_000, 0, 30_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 500_000_000);

        int128 crossBefore = ledger.getUserLedgerBalance(ALICE, TOKEN_HASH);
        int128 isoBefore = ledger.getIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH);

        vm.prank(address(operatorManager));
        ledger.executeMarginTransferV3(
            EventTypes.MarginTransferV3({
                accountId: ALICE,
                marginFromCross: marginFromCross,
                transferAssetHash: TOKEN_HASH,
                isoSymbolHash: SYMBOL_HASH_BTC_USDC,
                timestamp: 1678975214714
            }),
            3
        );

        int128 crossAfter = ledger.getUserLedgerBalance(ALICE, TOKEN_HASH);
        int128 isoAfter = ledger.getIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH);

        // Total (cross + iso) should be conserved
        assertEq(
            crossAfter + isoAfter,
            crossBefore + isoBefore,
            "margin transfer: total cross + iso conserved"
        );
        // Cross decreased by marginFromCross
        assertEq(crossAfter, crossBefore - marginFromCross, "cross delta == -marginFromCross");
        // Iso increased by marginFromCross
        assertEq(isoAfter, isoBefore + marginFromCross, "iso delta == marginFromCross");
    }

    // =================== Fuzz: liquidationV3 cross ===================

    function testFuzz_liquidationV3_cross(int128 positionQtyTransfer, int128 costPositionTransfer) public {
        vm.assume(positionQtyTransfer > -1_000_000_000 && positionQtyTransfer < 0); // closing long
        vm.assume(costPositionTransfer > -100_000_000 && costPositionTransfer < 0);

        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: 1_000_000_000,
                costPosition: 100_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 30_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 30_000_000,
                openingCost: 100_000_000,
                lastAdlPrice: 0
            })
        );

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](1);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: positionQtyTransfer,
            costPositionTransfer: costPositionTransfer,
            fee: 0,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        // Use isInsuranceAccount=true to skip calAverageEntryPrice (avoids SafeCast edge cases)
        // Focus: verify position qty and costPosition arithmetic
        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: ALICE,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: true,
                liquidationTransfers: transfers
            }),
            4
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_BTC_USDC);
        assertEq(pos.positionQty, 1_000_000_000 + positionQtyTransfer, "position qty updated correctly");
        assertEq(pos.costPosition, 100_000_000 + costPositionTransfer, "cost position updated correctly");
    }

    // =================== Fuzz: perpTradeV3 cross ===================

    function testFuzz_perpTradeV3_cross(int128 tradeQty, int128 notional, int128 fee) public {
        vm.assume(tradeQty != 0);
        vm.assume(tradeQty > -1_000_000_000 && tradeQty < 1_000_000_000);
        vm.assume(notional > -100_000_000 && notional < 100_000_000);
        vm.assume(fee >= 0 && fee < 1_000_000);

        // Fresh position (no prior position, no funding) → costPosition = notional + fee
        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: tradeQty,
                notional: notional,
                executedPrice: 250_000_000,
                fee: fee,
                sumUnitaryFundings: 0,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: tradeQty > 0 ? false : true,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(pos.positionQty, tradeQty, "fuzz: positionQty == tradeQty");
        assertEq(pos.costPosition, notional + fee, "fuzz: costPosition == notional + fee (no prior position, no funding)");
    }
}
