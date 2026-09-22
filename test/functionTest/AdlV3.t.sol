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

contract AdlV3Test is Test {
    bytes32 constant BROKER_HASH = 0x083098c593f395bea1de45dda552d9f14e8fcb0be3faaa7a1903c5477d7ba7fd;
    bytes32 constant TOKEN_HASH = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant SYMBOL_HASH_BTC_USDC = 0x1111101010101010101010101010101010101010101010101010101010101010;
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
        vaultManager.setAllowedChainToken(TOKEN_HASH, CHAIN_ID, true);

        feeManager.setLedgerAddress(address(ledger));

        marketManager.setOperatorManagerAddress(address(operatorManager));
        marketManager.setLedgerAddress(address(ledger));

        ledgerCrossChainManager.setLedger(address(ledger));
        ledgerCrossChainManager.setOperatorManager(address(operatorManager));
    }

    // =================== Cross margin ADL V3 ===================

    function test_adlV3_cross_margin() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: 10_000_000,
                costPosition: 1_340_402,
                lastSumUnitaryFundings: -623_710_000_000_000,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 134_040_200,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        vm.prank(address(operatorManager));
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -10_000_000,
                costPositionTransfer: -1_070_650,
                adlPrice: 1_070_650_000,
                sumUnitaryFundings: -97_240_000_000_000,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginToCross: 0
            }),
            1
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_BTC_USDC);
        assertEq(pos.positionQty, 0);
        assertEq(pos.lastExecutedPrice, 1_070_650_000);
        assertEq(pos.lastAdlPrice, 1_070_650_000);
        assertEq(pos.averageEntryPrice, 0); // fully closed
        assertEq(ledger.getUserLedgerLastEngineEventId(ALICE), 1);
    }

    function test_adlV3_cross_insurance_account() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 10_000_000_000, CHAIN_ID);
        ledger.cheatSetUserPosition(
            INSURANCE_FUND,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: -10_000_000,
                costPosition: -1_057_610,
                lastSumUnitaryFundings: -97_240_000_000_000,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        vm.prank(address(operatorManager));
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: INSURANCE_FUND,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: 10_000_000,
                costPositionTransfer: 1_070_650,
                adlPrice: 1_070_650_000,
                sumUnitaryFundings: -97_240_000_000_000,
                timestamp: 1678975214714,
                isInsuranceAccount: true,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginToCross: 0
            }),
            2
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(INSURANCE_FUND, SYMBOL_HASH_BTC_USDC);
        assertEq(pos.positionQty, 0);
        // Insurance account does NOT call calAverageEntryPrice
        assertEq(pos.averageEntryPrice, 0);
    }

    // =================== Isolated margin ADL V3 ===================

    function test_adlV3_iso_margin_with_marginToCross() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        // Use openingCost=0 to avoid SafeCast issues in calAverageEntryPrice
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 10_000_000, 1_340_402, -623_710_000_000_000, 20_000_000, 0, 134_040_200, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 500_000_000);

        vm.prank(address(operatorManager));
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -10_000_000,
                costPositionTransfer: -1_070_650,
                adlPrice: 1_070_650_000,
                sumUnitaryFundings: -97_240_000_000_000,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 1,
                isoMarginAssetHash: TOKEN_HASH,
                marginToCross: 200_000_000 // release margin to cross
            }),
            3
        );

        // Iso position fully closed
        (int128 posQty,,,uint128 lastExecPrice,,,,uint128 lastAdlPrice) =
            ledger.getIsoPerpPosition(ALICE, SYMBOL_HASH_BTC_USDC);
        assertEq(posQty, 0);
        assertEq(lastExecPrice, 1_070_650_000);
        assertEq(lastAdlPrice, 1_070_650_000);

        // Margin transferred from iso to cross
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH), 300_000_000); // 500M - 200M
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_200_000_000); // 1B + 200M
    }

    function testRevert_adlV3_iso_negative_marginToCross() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 10_000_000, 1_340_402, -623_710_000_000_000, 20_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 500_000_000);

        vm.prank(address(operatorManager));
        vm.expectRevert(abi.encodeWithSelector(IError.IsoAdlMarginToCrossAmountInvalid.selector, int128(-100_000_000)));
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -5_000_000,
                costPositionTransfer: -500_000,
                adlPrice: 1_000_000_000,
                sumUnitaryFundings: -97_240_000_000_000,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 1,
                isoMarginAssetHash: TOKEN_HASH,
                marginToCross: -100_000_000
            }),
            4
        );
    }

    function testRevert_adlV3_position_qty_zero() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        // No position set => positionQty = 0

        vm.prank(address(operatorManager));
        vm.expectRevert(
            abi.encodeWithSelector(IError.UserPerpPositionQtyZero.selector, ALICE, SYMBOL_HASH_BTC_USDC)
        );
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -500_000_000,
                costPositionTransfer: -50_000_000,
                adlPrice: 31_000_000,
                sumUnitaryFundings: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginToCross: 0
            }),
            5
        );
    }

    function testRevert_adlV3_transfer_qty_exceeds_position() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: 500_000_000,
                costPosition: 50_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 30_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        vm.prank(address(operatorManager));
        vm.expectRevert(
            abi.encodeWithSelector(IError.InsurancePositionQtyInvalid.selector, int128(-1_000_000_000), int128(500_000_000))
        );
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -1_000_000_000, // exceeds position
                costPositionTransfer: -100_000_000,
                adlPrice: 31_000_000,
                sumUnitaryFundings: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginToCross: 0
            }),
            6
        );
    }

    function testRevert_adlV3_symbol_not_allowed() public {
        bytes32 unknownSymbol = 0x9999999999999999999999999999999999999999999999999999999999999999;

        vm.prank(address(operatorManager));
        vm.expectRevert(IError.SymbolNotAllowed.selector);
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: unknownSymbol,
                positionQtyTransfer: -500_000_000,
                costPositionTransfer: -50_000_000,
                adlPrice: 31_000_000,
                sumUnitaryFundings: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginToCross: 0
            }),
            7
        );
    }

    // =================== Boundary: exact position close ===================

    function test_adlV3_cross_exact_position_close() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: 500_000_000,
                costPosition: 50_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 30_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 30_000_000,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        // positionQtyTransfer exactly negates positionQty
        vm.prank(address(operatorManager));
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -500_000_000,
                costPositionTransfer: -50_000_000,
                adlPrice: 31_000_000,
                sumUnitaryFundings: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginToCross: 0
            }),
            8
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_BTC_USDC);
        assertEq(pos.positionQty, 0, "exact close: positionQty = 0");
        assertEq(pos.costPosition, 0, "exact close: costPosition = 0");
        assertEq(pos.averageEntryPrice, 0, "exact close: averageEntryPrice = 0");
    }

    // =================== Boundary: zero marginToCross ===================

    function test_adlV3_iso_zero_marginToCross() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 10_000_000, 1_340_402, 0, 20_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 500_000_000);

        vm.prank(address(operatorManager));
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -5_000_000,
                costPositionTransfer: -670_201,
                adlPrice: 1_070_650_000,
                sumUnitaryFundings: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 1,
                isoMarginAssetHash: TOKEN_HASH,
                marginToCross: 0 // zero: no margin transfer
            }),
            9
        );

        // Iso margin unchanged
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH), 500_000_000, "zero marginToCross: iso margin unchanged");
        // Cross balance unchanged
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000, "zero marginToCross: cross balance unchanged");
    }

    // =================== Event assertion ===================

    function test_adlV3_emits_AdlResultV3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: 10_000_000,
                costPosition: 1_340_402,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 134_040_200,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        // Expect AdlResultV3 event (indexed: eventId=any, accountId=ALICE)
        vm.expectEmit(false, true, false, true);
        emit AdlResultV3(
            0, // eventId: don't check
            ALICE,
            false, // isInsuranceAccount
            SYMBOL_HASH_BTC_USDC,
            -10_000_000, // positionQtyTransfer
            -1_070_650, // costPositionTransfer
            1_070_650_000, // adlPrice
            0, // sumUnitaryFundings
            0, // marginMode
            bytes32(0), // isoMarginAssetHash
            int128(0), // isoMargin (marginToCross)
            10 // lastEngineEventId
        );

        vm.prank(address(operatorManager));
        ledger.executeAdlV3(
            EventTypes.AdlV3({
                accountId: ALICE,
                symbolHash: SYMBOL_HASH_BTC_USDC,
                positionQtyTransfer: -10_000_000,
                costPositionTransfer: -1_070_650,
                adlPrice: 1_070_650_000,
                sumUnitaryFundings: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                marginMode: 0,
                isoMarginAssetHash: bytes32(0),
                marginToCross: 0
            }),
            10
        );
    }

    // Re-declare event for vm.expectEmit
    event AdlResultV3(
        uint64 indexed eventId,
        bytes32 indexed accountId,
        bool isInsuranceAccount,
        bytes32 symbolHash,
        int128 positionQtyTransfer,
        int128 costPositionTransfer,
        uint128 adlPrice,
        int128 sumUnitaryFundings,
        uint8 marginMode,
        bytes32 isoMarginAssetHash,
        int128 isoMargin,
        uint64 lastEngineEventId
    );
}
