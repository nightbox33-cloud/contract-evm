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

contract PerpTradeUploadV3Test is Test {
    bytes32 constant BROKER_HASH = 0x083098c593f395bea1de45dda552d9f14e8fcb0be3faaa7a1903c5477d7ba7fd;
    bytes32 constant TOKEN_HASH = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant TOKEN_HASH_2 = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eab;
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
        vaultManager.setAllowedChainToken(TOKEN_HASH, CHAIN_ID, true);
        if (!vaultManager.getAllowedSymbol(SYMBOL_HASH_ETH_USDC)) {
            vaultManager.setAllowedSymbol(SYMBOL_HASH_ETH_USDC, true);
        }

        feeManager.setLedgerAddress(address(ledger));

        marketManager.setOperatorManagerAddress(address(operatorManager));
        marketManager.setLedgerAddress(address(ledger));

        ledgerCrossChainManager.setLedger(address(ledger));
        ledgerCrossChainManager.setOperatorManager(address(operatorManager));
    }

    // =================== Cross margin (marginMode=0) tests ===================

    function test_v3_cross_margin_open_position() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 200_000_000,
                notional: 5_000_000,
                executedPrice: 250_000_000,
                fee: 5_000,
                sumUnitaryFundings: 1_000_000_000_000_001,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(pos.positionQty, 200_000_000);
        assertEq(pos.costPosition, 5_005_000); // notional + fee
        assertEq(pos.lastSumUnitaryFundings, 1_000_000_000_000_001);
        assertEq(pos.lastExecutedPrice, 250_000_000);
        // balance unchanged for cross margin (fee goes to costPosition)
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000);
    }

    function test_v3_cross_margin_close_position() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: 200_000_000,
                costPosition: 5_000_000,
                lastSumUnitaryFundings: 1_000_000_000_000_001,
                lastExecutedPrice: 250_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 250_000_000,
                openingCost: 5_000_000,
                lastAdlPrice: 0
            })
        );

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: -200_000_000,
                notional: -5_000_000,
                executedPrice: 250_000_000,
                fee: 5_000,
                sumUnitaryFundings: 1_000_000_000_000_001, // same funding, no funding fee
                tradeId: 2,
                matchId: 101,
                timestamp: 1678975214715,
                side: true,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(pos.positionQty, 0);
        assertEq(pos.costPosition, 5_000); // residual fee
    }

    // =================== Isolated margin (marginMode=1) tests ===================

    function test_v3_iso_margin_open_position() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 100_000_000,
                notional: 2_500_000,
                executedPrice: 250_000_000,
                fee: 3_000,
                sumUnitaryFundings: 1_000_000_000_000_001,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 1,
                isoMarginAssetHash: TOKEN_HASH,
                marginFromCross: 500_000_000 // transfer 500 USDC from cross to iso
            })
        );

        // Check iso position
        (int128 posQty, int128 costPos, int128 lastFunding, uint128 lastExecPrice,,,,) =
            ledger.getIsoPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(posQty, 100_000_000);
        assertEq(costPos, 2_503_000); // notional + fee
        assertEq(lastFunding, 1_000_000_000_000_001);
        assertEq(lastExecPrice, 250_000_000);

        // Check margin transferred from cross to iso
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 500_000_000); // 1B - 500M
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH), 500_000_000);
    }

    function test_v3_iso_margin_negative_marginFromCross_skipped() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_ETH_USDC, 100_000_000, 2_500_000, 1_000_000_000_000_001, 250_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 500_000_000);

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: -50_000_000,
                notional: -1_250_000,
                executedPrice: 250_000_000,
                fee: 1_500,
                sumUnitaryFundings: 1_000_000_000_000_001,
                tradeId: 2,
                matchId: 101,
                timestamp: 1678975214715,
                side: true,
                marginMode: 1,
                isoMarginAssetHash: TOKEN_HASH,
                marginFromCross: -200_000_000 // negative: transfer iso to cross, should be skipped here
            })
        );

        // Balance unchanged (negative marginFromCross not processed in trade)
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000);
        // Iso margin unchanged
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH), 500_000_000);
    }

    function test_v3_cross_margin_updates_lastPerpTradeId() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 100_000_000,
                notional: 2_500_000,
                executedPrice: 250_000_000,
                fee: 0,
                sumUnitaryFundings: 0,
                tradeId: 42,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );

        // lastPerpTradeId should be updated
        // We can verify via the event or indirectly; the test simply checks no revert
    }

    function testRevert_v3_symbol_not_allowed() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        bytes32 unknownSymbol = 0x9999999999999999999999999999999999999999999999999999999999999999;

        vm.prank(address(operatorManager));
        vm.expectRevert(IError.SymbolNotAllowed.selector);
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: unknownSymbol,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 100_000_000,
                notional: 2_500_000,
                executedPrice: 250_000_000,
                fee: 0,
                sumUnitaryFundings: 0,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );
    }

    function testRevert_v3_only_operator_manager() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.expectRevert(IError.OnlyOperatorCanCall.selector);
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 100_000_000,
                notional: 2_500_000,
                executedPrice: 250_000_000,
                fee: 0,
                sumUnitaryFundings: 0,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );
    }

    function test_v3_iso_margin_with_fee_swap() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 100_000_000,
                notional: 2_500_000,
                executedPrice: 250_000_000,
                fee: 10_000,
                sumUnitaryFundings: 0,
                tradeId: 5,
                matchId: 200,
                timestamp: 1678975214714,
                side: false,
                marginMode: 1,
                isoMarginAssetHash: TOKEN_HASH,
                marginFromCross: 300_000_000
            })
        );

        // Iso position cost includes fee
        (int128 posQty, int128 costPos,,,,,,) = ledger.getIsoPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(posQty, 100_000_000);
        assertEq(costPos, 2_510_000); // notional(2_500_000) + fee(10_000)

        // Fee collector should have the fee on its perp position
        bytes32 feeCollectorHash = feeManager.getFeeCollector(IFeeManager.FeeCollectorType.FuturesFeeCollector);
        AccountTypes.PerpPosition memory feePos = ledger.getPerpPosition(feeCollectorHash, SYMBOL_HASH_ETH_USDC);
        assertEq(feePos.costPosition, -10_000); // negative cost = fee collected
    }

    // =================== Independent hand-calc verification ===================

    function test_v3_cross_margin_funding_fee_calculation() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        // Set up existing position with known lastSumUnitaryFundings
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: 1_000_000, // 1e6
                costPosition: 0,
                lastSumUnitaryFundings: 1_000_000_000_000_000, // 1e15
                lastExecutedPrice: 250_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 250_000_000,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        // Hand calculation:
        // accruedFeeUnconverted = positionQty * (newFunding - lastFunding)
        //                       = 1e6 * (1.1e15 - 1e15) = 1e6 * 1e14 = 1e20
        // accruedFee = 1e20 / 1e17 = 1000
        // remainder = 1e20 - 1000 * 1e17 = 0 → no ceiling
        // costPosition after funding = 0 + 1000 = 1000
        // then: costPosition += notional(5_000_000) → 5_001_000
        // then: costPosition += fee(5_000) → 5_006_000

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 200_000_000,
                notional: 5_000_000,
                executedPrice: 250_000_000,
                fee: 5_000,
                sumUnitaryFundings: 1_100_000_000_000_000, // 1.1e15
                tradeId: 10,
                matchId: 200,
                timestamp: 1678975214714,
                side: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        // funding fee = 1000, notional = 5_000_000, fee = 5_000
        assertEq(pos.costPosition, 1000 + 5_000_000 + 5_000, "costPosition = fundingFee + notional + fee");
        assertEq(pos.lastSumUnitaryFundings, 1_100_000_000_000_000);
    }

    // =================== Boundary tests ===================

    function test_v3_cross_zero_fee() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 100_000_000,
                notional: 2_500_000,
                executedPrice: 250_000_000,
                fee: 0, // zero fee
                sumUnitaryFundings: 0,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        // costPosition = notional only (fee=0 skips _feeSwapPosition)
        assertEq(pos.costPosition, 2_500_000, "zero fee: costPosition = notional only");
        // Fee collector should have no position change
        bytes32 feeCollectorHash = feeManager.getFeeCollector(IFeeManager.FeeCollectorType.FuturesFeeCollector);
        AccountTypes.PerpPosition memory feePos = ledger.getPerpPosition(feeCollectorHash, SYMBOL_HASH_ETH_USDC);
        assertEq(feePos.costPosition, 0, "zero fee: fee collector costPosition unchanged");
    }

    function test_v3_iso_zero_marginFromCross() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 100_000_000,
                notional: 2_500_000,
                executedPrice: 250_000_000,
                fee: 1_000,
                sumUnitaryFundings: 0,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 1,
                isoMarginAssetHash: TOKEN_HASH,
                marginFromCross: 0 // zero margin transfer
            })
        );

        // Cross balance unchanged (no margin transfer)
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000, "zero marginFromCross: balance unchanged");
        // Iso margin unchanged (no margin transfer)
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH), 0, "zero marginFromCross: iso margin = 0");
        // Position still created
        (int128 posQty,,,,,,,) = ledger.getIsoPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(posQty, 100_000_000);
    }

    // =================== Event assertion ===================

    function test_v3_cross_emits_ProcessValidatedFuturesV3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        vm.expectEmit(true, true, false, true);
        emit ProcessValidatedFuturesV3(
            ALICE,
            SYMBOL_HASH_ETH_USDC,
            TOKEN_HASH,
            200_000_000, // tradeQty
            5_000_000, // notional
            250_000_000, // executedPrice
            5_000, // fee
            1_000_000_000_000_001, // sumUnitaryFundings
            1, // tradeId
            100, // matchId
            false, // side
            0, // marginMode
            bytes32(0), // isoMarginAssetHash
            int128(0) // isoMargin (marginFromCross)
        );

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV3(
            PerpTypes.FuturesTradeUploadV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_ETH_USDC,
                feeAssetHash: TOKEN_HASH,
                tradeQty: 200_000_000,
                notional: 5_000_000,
                executedPrice: 250_000_000,
                fee: 5_000,
                sumUnitaryFundings: 1_000_000_000_000_001,
                tradeId: 1,
                matchId: 100,
                timestamp: 1678975214714,
                side: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginFromCross: 0
            })
        );
    }

    // Re-declare the event for vm.expectEmit
    event ProcessValidatedFuturesV3(
        bytes32 indexed accountId,
        bytes32 indexed symbolHash,
        bytes32 feeAssetHash,
        int128 tradeQty,
        int128 notional,
        uint128 executedPrice,
        int128 fee,
        int128 sumUnitaryFundings,
        uint64 tradeId,
        uint64 matchId,
        bool side,
        uint8 marginMode,
        bytes32 isoMarginAssetHash,
        int128 isoMargin
    );
}
