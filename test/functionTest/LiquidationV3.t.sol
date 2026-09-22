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

contract LiquidationV3Test is Test {
    bytes32 constant BROKER_HASH = 0x083098c593f395bea1de45dda552d9f14e8fcb0be3faaa7a1903c5477d7ba7fd;
    bytes32 constant TOKEN_HASH = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant SYMBOL_HASH_BTC_USDC = 0x1111101010101010101010101010101010101010101010101010101010101010;
    bytes32 constant SYMBOL_HASH_ETH_USDC = 0x2222101010101010101010101010101010101010101010101010101010101010;
    uint256 constant CHAIN_ID = 986532;
    bytes32 constant LIQUIDATED_ACCOUNT_ID = 0xa11ce00000000000000000000000000000000000000000000000000000000000;
    bytes32 constant LIQUIDATOR_ACCOUNT_ID = 0xb0b0000000000000000000000000000000000000000000000000000000000000;
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

        ledger.cheatDeposit(LIQUIDATED_ACCOUNT_ID, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(LIQUIDATOR_ACCOUNT_ID, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 10_000_000_000, CHAIN_ID);
    }

    // =================== Cross margin liquidation V3 ===================

    function test_liquidationV3_cross_single_symbol() public {
        ledger.cheatSetUserPosition(
            LIQUIDATED_ACCOUNT_ID,
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
            positionQtyTransfer: -1_000_000_000,
            costPositionTransfer: -100_000_000,
            fee: 5_000,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 50_000,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            1
        );

        // Cross balance: +insuranceTransfer
        assertEq(ledger.getUserLedgerBalance(LIQUIDATED_ACCOUNT_ID, TOKEN_HASH), 1_000_000_000 + 50_000);
        // Position: positionQty=0 but costPosition = 100M + (-100M + 5K) = 5K (fee residual)
        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC);
        assertEq(pos.positionQty, 0);
        assertEq(pos.costPosition, 5_000); // fee residual
        assertEq(ledger.getUserLedgerLastEngineEventId(LIQUIDATED_ACCOUNT_ID), 1);
    }

    function test_liquidationV3_cross_multi_symbol() public {
        ledger.cheatSetUserPosition(
            LIQUIDATED_ACCOUNT_ID,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: 500_000_000,
                costPosition: 50_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 30_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 30_000_000,
                openingCost: 50_000_000,
                lastAdlPrice: 0
            })
        );
        ledger.cheatSetUserPosition(
            LIQUIDATED_ACCOUNT_ID,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: -300_000_000,
                costPosition: -30_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 20_000_000,
                openingCost: -30_000_000,
                lastAdlPrice: 0
            })
        );

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](2);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: -500_000_000,
            costPositionTransfer: -50_000_000,
            fee: 3_000,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });
        transfers[1] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            positionQtyTransfer: 300_000_000,
            costPositionTransfer: 30_000_000,
            fee: 2_000,
            markPrice: 19_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            2
        );

        // Both positions should be closed
        AccountTypes.PerpPosition memory posBtc = ledger.getPerpPosition(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC);
        assertEq(posBtc.positionQty, 0);
        AccountTypes.PerpPosition memory posEth = ledger.getPerpPosition(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_ETH_USDC);
        assertEq(posEth.positionQty, 0);
    }

    // =================== Isolated margin liquidation V3 ===================

    function test_liquidationV3_iso_single_symbol() public {
        // Set up iso position
        ledger.cheatSetUserIsoPosition(
            LIQUIDATED_ACCOUNT_ID,
            SYMBOL_HASH_BTC_USDC,
            1_000_000_000,
            100_000_000,
            0,
            30_000_000,
            0,
            30_000_000,
            100_000_000,
            0
        );
        ledger.cheatSetUserIsoMargin(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 500_000_000);

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](1);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: -1_000_000_000,
            costPositionTransfer: -100_000_000,
            fee: 5_000,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH,
            marginToCross: 200_000_000 // release remaining margin to cross
        });

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 30_000, // goes to iso margin
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            3
        );

        // Iso position: positionQty=0 but costPosition has fee residual
        (int128 posQty, int128 costPos,,,,,,) =
            ledger.getIsoPerpPosition(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC);
        assertEq(posQty, 0);
        assertEq(costPos, 5_000); // fee residual

        // Cross balance: original 1B + 200M marginToCross = 1.2B
        assertEq(ledger.getUserLedgerBalance(LIQUIDATED_ACCOUNT_ID, TOKEN_HASH), 1_200_000_000);
    }

    function test_liquidationV3_iso_insurance_to_margin() public {
        // Set up iso position
        ledger.cheatSetUserIsoPosition(
            LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, 500_000_000, 50_000_000, 0, 30_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 100_000_000);

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](1);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: -250_000_000,
            costPositionTransfer: -25_000_000,
            fee: 1_000,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH,
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 20_000, // for iso
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            4
        );

        // Insurance goes to iso margin
        assertEq(
            ledger.getIsoMargin(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, TOKEN_HASH),
            100_000_000 + 20_000
        );
        // Cross balance unchanged (no marginToCross)
        assertEq(ledger.getUserLedgerBalance(LIQUIDATED_ACCOUNT_ID, TOKEN_HASH), 1_000_000_000);
    }

    // =================== Iso liquidation full settled (position NOT deleted) ===================

    function test_liquidationV3_iso_full_settled_keeps_position() public {
        // Iso position that will be fully settled after liquidation (positionQty=0, costPosition=0)
        ledger.cheatSetUserIsoPosition(
            LIQUIDATED_ACCOUNT_ID,
            SYMBOL_HASH_BTC_USDC,
            1_000_000_000,  // positionQty
            100_000_000,    // costPosition
            0,              // lastSumUnitaryFundings
            30_000_000,     // lastExecutedPrice
            0,              // lastSettledPrice
            30_000_000,     // averageEntryPrice
            100_000_000,    // openingCost
            0               // lastAdlPrice
        );
        ledger.cheatSetUserIsoMargin(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 500_000_000);

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](1);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: -1_000_000_000,
            costPositionTransfer: -100_000_000,
            fee: 0, // no fee residual → isFullSettled would be true
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH,
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            10
        );

        // Position is NOT deleted even though isFullSettled (positionQty=0, costPosition=0)
        (int128 posQty, int128 costPos,, uint128 lastExecPrice,,,,) =
            ledger.getIsoPerpPosition(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC);
        assertEq(posQty, 0);
        assertEq(costPos, 0);
        // Key: position fields preserved (not zeroed by delete)
        assertEq(lastExecPrice, 28_000_000, "iso position not deleted: lastExecPrice preserved");
        // Margin preserved
        assertEq(ledger.getIsoMargin(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, TOKEN_HASH), 500_000_000);
    }

    // =================== Error cases ===================

    function testRevert_liquidationV3_invalid_margin_mode() public {
        ledger.cheatSetUserPosition(
            LIQUIDATED_ACCOUNT_ID,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: 1_000_000_000,
                costPosition: 100_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 30_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](1);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: -1_000_000_000,
            costPositionTransfer: -100_000_000,
            fee: 0,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 2, // invalid!
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        vm.expectRevert(abi.encodeWithSelector(IError.InvalidMarginMode.selector, uint8(2)));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            5
        );
    }

    function testRevert_liquidationV3_symbol_not_allowed() public {
        bytes32 unknownSymbol = 0x9999999999999999999999999999999999999999999999999999999999999999;

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](1);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: unknownSymbol,
            positionQtyTransfer: -1_000_000_000,
            costPositionTransfer: -100_000_000,
            fee: 0,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        vm.expectRevert(IError.SymbolNotAllowed.selector);
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            6
        );
    }

    // =================== Error: multiple iso transfers not allowed ===================

    function testRevert_liquidationV3_multiple_iso_transfers() public {
        ledger.cheatSetUserIsoPosition(
            LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, 500_000_000, 50_000_000, 0, 30_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 100_000_000);
        ledger.cheatSetUserIsoPosition(
            LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_ETH_USDC, 300_000_000, 30_000_000, 0, 20_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(LIQUIDATED_ACCOUNT_ID, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 100_000_000);

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](2);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: -500_000_000,
            costPositionTransfer: -50_000_000,
            fee: 0,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 1, // iso
            isoMarginAssetHash: TOKEN_HASH,
            marginToCross: 0
        });
        transfers[1] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            positionQtyTransfer: -300_000_000,
            costPositionTransfer: -30_000_000,
            fee: 0,
            markPrice: 19_000_000,
            sumUnitaryFundings: 0,
            marginMode: 1, // iso
            isoMarginAssetHash: TOKEN_HASH,
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        // Multiple transfers with iso margin mode should revert
        // The require check enforces all must be cross (marginMode==0) for multi-transfer
        vm.expectRevert("Invalid margin mode for multiple liquidation transfers");
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            11
        );
    }

    // =================== Boundary: negative insuranceTransferAmount (cross) ===================

    function test_liquidationV3_cross_negative_insurance() public {
        ledger.cheatSetUserPosition(
            LIQUIDATED_ACCOUNT_ID,
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
            positionQtyTransfer: -1_000_000_000,
            costPositionTransfer: -100_000_000,
            fee: 0,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: -50_000, // negative: sub from liquidated account
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            7
        );

        // Cross balance should decrease by absolute insurance amount
        assertEq(
            ledger.getUserLedgerBalance(LIQUIDATED_ACCOUNT_ID, TOKEN_HASH),
            1_000_000_000 - 50_000,
            "negative insurance: balance decreased"
        );
    }

    // =================== Boundary: insurance account skips calAvg ===================

    function test_liquidationV3_insurance_account_skip_calAvg() public {
        ledger.cheatSetUserPosition(
            INSURANCE_FUND,
            SYMBOL_HASH_BTC_USDC,
            AccountTypes.PerpPosition({
                positionQty: -500_000_000,
                costPosition: -50_000_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 30_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        EventTypes.LiquidationTransferV3[] memory transfers = new EventTypes.LiquidationTransferV3[](1);
        transfers[0] = EventTypes.LiquidationTransferV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            positionQtyTransfer: 500_000_000,
            costPositionTransfer: 50_000_000,
            fee: 1_000,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: INSURANCE_FUND,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 0,
                timestamp: 1678975214714,
                isInsuranceAccount: true, // insurance account → needCalAvg=false
                liquidationTransfers: transfers
            }),
            8
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(INSURANCE_FUND, SYMBOL_HASH_BTC_USDC);
        assertEq(pos.positionQty, 0);
        // averageEntryPrice stays 0 because calAverageEntryPrice was skipped
        assertEq(pos.averageEntryPrice, 0, "insurance account: calAvg skipped");
    }

    // =================== Event assertion ===================

    function test_liquidationV3_emits_events() public {
        ledger.cheatSetUserPosition(
            LIQUIDATED_ACCOUNT_ID,
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
            positionQtyTransfer: -1_000_000_000,
            costPositionTransfer: -100_000_000,
            fee: 5_000,
            markPrice: 28_000_000,
            sumUnitaryFundings: 0,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0),
            marginToCross: 0
        });

        // Expect LiquidationTransferV3 event
        vm.expectEmit(true, true, false, true);
        emit LiquidationTransferV3(
            LIQUIDATED_ACCOUNT_ID,
            SYMBOL_HASH_BTC_USDC,
            -1_000_000_000,
            -100_000_000,
            5_000,
            28_000_000,
            0,
            0,
            bytes32(0),
            int128(0)
        );

        // Expect LiquidationResultV3 event
        vm.expectEmit(false, true, false, true);
        emit LiquidationResultV3(
            0, // eventId: don't check
            LIQUIDATED_ACCOUNT_ID,
            TOKEN_HASH,
            int128(50_000),
            false,
            9
        );

        vm.prank(address(operatorManager));
        ledger.executeLiquidationV3(
            EventTypes.LiquidationV3({
                accountId: LIQUIDATED_ACCOUNT_ID,
                liquidatedAssetHash: TOKEN_HASH,
                insuranceTransferAmount: 50_000,
                timestamp: 1678975214714,
                isInsuranceAccount: false,
                liquidationTransfers: transfers
            }),
            9
        );
    }

    // Re-declare events for vm.expectEmit
    event LiquidationTransferV3(
        bytes32 indexed accountId,
        bytes32 indexed symbolHash,
        int128 positionQtyTransfer,
        int128 costPositionTransfer,
        int128 fee,
        uint128 markPrice,
        int128 sumUnitaryFundings,
        uint8 marginMode,
        bytes32 isoMarginAssetHash,
        int128 marginToCross
    );

    event LiquidationResultV3(
        uint64 indexed eventId,
        bytes32 indexed accountId,
        bytes32 liquidatedAssetHash,
        int128 insuranceTransferAmount,
        bool isInsuranceAccount,
        uint64 lastEngineEventId
    );
}
