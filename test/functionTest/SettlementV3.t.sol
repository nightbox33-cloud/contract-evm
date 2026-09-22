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

contract SettlementV3Test is Test {
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

        // Seed balances
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(BOB, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 10_000_000_000, CHAIN_ID);
    }

    // =================== Cross margin settlement ===================

    function test_settlementV3_cross_single_symbol() public {
        // Set up cross position
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: 1_000_000_000,
                costPosition: 100_000_000,
                lastSumUnitaryFundings: 10_000_000_000_000_000,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 10_000_000_000_000_001,
            settledAmount: -50_000,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -50_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            1
        );

        // Cross balance should decrease by settledAmount
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000 - 50_000);
        // Position should be updated
        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(pos.costPosition, 100_000_000 - 50_000 + 1); // + funding fee (rounded up)
        assertEq(pos.lastSumUnitaryFundings, 10_000_000_000_000_001);
        assertEq(pos.lastExecutedPrice, 25_000_000);
        assertEq(pos.lastSettledPrice, 25_000_000);
        assertEq(ledger.getUserLedgerLastEngineEventId(ALICE), 1);
    }

    // =================== Isolated margin settlement ===================

    function test_settlementV3_iso_single_symbol() public {
        // Set up iso position
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_ETH_USDC, 1_000_000_000, 100_000_000, 10_000_000_000_000_000, 20_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 500_000_000);

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 10_000_000_000_000_000, // same as last, no funding fee
            settledAmount: -30_000,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -30_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            2
        );

        // Iso margin should decrease
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH), 500_000_000 - 30_000);
        // Cross balance unchanged
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000);
        // Iso position updated
        (int128 posQty, int128 costPos, int128 lastFunding, uint128 lastExecPrice, uint128 lastSettledPrice,,,) =
            ledger.getIsoPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(posQty, 1_000_000_000);
        assertEq(costPos, 100_000_000 - 30_000);
        assertEq(lastFunding, 10_000_000_000_000_000);
        assertEq(lastExecPrice, 25_000_000);
        assertEq(lastSettledPrice, 25_000_000);
    }

    // =================== Mixed settlement (cross + iso) ===================

    function test_settlementV3_mixed_cross_and_iso() public {
        // Cross position on BTC
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
        // Iso position on ETH
        ledger.cheatSetUserIsoPosition(ALICE, SYMBOL_HASH_ETH_USDC, 1_000_000_000, 100_000_000, 0, 20_000_000, 0, 0, 0, 0);
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 300_000_000);

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](2);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_BTC_USDC,
            markPrice: 31_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -20_000,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });
        execs[1] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -10_000,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -30_000, // total = -20_000 + -10_000
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            3
        );

        // Cross balance affected by cross settlement only
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000 - 20_000);
        // Iso margin affected by iso settlement
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH), 300_000_000 - 10_000);
    }

    // =================== Settlement with insurance (now always reverts) ===================

    function testRevert_settlementV3_nonzero_insurance_transfer_cross() public {
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

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -100_000,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });

        vm.prank(address(operatorManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                IError.InsuranceTransferAmountInvalid.selector,
                int128(1_000_000_000), // Alice's balance
                uint128(50_000),
                int128(-100_000)
            )
        );
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -100_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: INSURANCE_FUND,
                insuranceTransferAmount: 50_000,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            4
        );
    }

    function testRevert_settlementV3_nonzero_insurance_transfer_iso() public {
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_ETH_USDC, 1_000_000_000, 100_000_000, 0, 20_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 500_000_000);

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -30_000,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH
        });

        vm.prank(address(operatorManager));
        vm.expectRevert(
            abi.encodeWithSelector(
                IError.InsuranceTransferAmountInvalid.selector,
                int128(1_000_000_000), // Alice's cross balance for settledAssetHash
                uint128(10_000),
                int128(-30_000)
            )
        );
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -30_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: INSURANCE_FUND,
                insuranceTransferAmount: 10_000,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            4
        );
    }

    // =================== Settlement amount mismatch ===================

    function testRevert_settlementV3_total_amount_mismatch() public {
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

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -50_000,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });

        vm.prank(address(operatorManager));
        vm.expectRevert(abi.encodeWithSelector(IError.TotalSettleAmountNotMatch.selector, int128(-50_000)));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -100_000, // mismatch!
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            5
        );
    }

    // =================== Iso settlement full settled (position NOT deleted) ===================

    function test_settlementV3_iso_full_settled_keeps_position() public {
        // Iso position that will be fully settled (positionQty=0, costPosition becomes 0)
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_ETH_USDC, 0, 50_000, 0, 20_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 300_000_000);

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -50_000,
            marginMode: 1,
            isoMarginAssetHash: TOKEN_HASH
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -50_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            6
        );

        // Position is NOT deleted even though isFullSettled (positionQty=0, costPosition=0)
        (int128 posQty, int128 costPos,, uint128 lastExecPrice, uint128 lastSettledPrice,,,) =
            ledger.getIsoPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(posQty, 0);
        assertEq(costPos, 0);
        // Key assertion: position fields are preserved (not zeroed by delete)
        assertEq(lastExecPrice, 25_000_000, "iso position not deleted: lastExecPrice preserved");
        assertEq(lastSettledPrice, 25_000_000, "iso position not deleted: lastSettledPrice preserved");
        // Margin is also preserved
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH), 300_000_000 - 50_000);
    }

    function testRevert_settlementV3_insurance_transfer_to_self_now_reverts_invalid() public {
        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](0);

        vm.prank(address(operatorManager));
        // insuranceTransferAmount != 0 now always reverts, regardless of accountId == insuranceAccountId
        vm.expectRevert(
            abi.encodeWithSelector(
                IError.InsuranceTransferAmountInvalid.selector,
                int128(1_000_000_000),
                uint128(50_000),
                int128(0)
            )
        );
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: 0,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: ALICE, // same as accountId, but irrelevant now
                insuranceTransferAmount: 50_000,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            7
        );
    }

    // =================== Independent hand-calc: ceiling rounding ===================

    function test_settlementV3_cross_funding_fee_ceiling_rounding() public {
        // positionQty=1, lastSumUnitaryFundings=0, new sumUnitaryFundings=1
        // accruedFeeUnconverted = 1 * (1 - 0) = 1
        // accruedFee = 1 / 1e17 = 0
        // remainder = 1 - 0*1e17 = 1 > 0 → ceiling: accruedFee = 1
        // costPosition += 1 (funding fee) + settledAmount
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: 1,
                costPosition: 0,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 1, // tiny funding change
            settledAmount: -500,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -500,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            8
        );

        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        // costPosition = 0 + 1 (ceiling funding fee) + (-500) = -499
        assertEq(pos.costPosition, -499, "ceiling rounding: costPosition = fundingFee(1) + settledAmount(-500)");
        assertEq(pos.lastSumUnitaryFundings, 1);
    }

    // =================== Boundary: zero executions ===================

    function test_settlementV3_zero_executions() public {
        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](0);

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: 0,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            9
        );

        // Balance unchanged
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000);
        assertEq(ledger.getUserLedgerLastEngineEventId(ALICE), 9);
    }

    // =================== Boundary: cross full settle deletes position ===================

    function test_settlementV3_cross_full_settled_deletes_position() public {
        // positionQty=0, costPosition=50_000. settledAmount=-50_000 → costPosition=0 → delete
        ledger.cheatSetUserPosition(
            ALICE,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: 0,
                costPosition: 50_000,
                lastSumUnitaryFundings: 0,
                lastExecutedPrice: 20_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: 0,
                openingCost: 0,
                lastAdlPrice: 0
            })
        );

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -50_000,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -50_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            10
        );

        // Position should be deleted (isFullSettled: positionQty=0, costPosition=0)
        AccountTypes.PerpPosition memory pos = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(pos.positionQty, 0);
        assertEq(pos.costPosition, 0);
        assertEq(pos.lastExecutedPrice, 0, "deleted position: lastExecutedPrice reset to 0");
        assertEq(pos.lastSettledPrice, 0, "deleted position: lastSettledPrice reset to 0");
    }

    // =================== Event assertion ===================

    function test_settlementV3_emits_events() public {
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

        EventTypes.SettlementExecutionV3[] memory execs = new EventTypes.SettlementExecutionV3[](1);
        execs[0] = EventTypes.SettlementExecutionV3({
            symbolHash: SYMBOL_HASH_ETH_USDC,
            markPrice: 25_000_000,
            sumUnitaryFundings: 0,
            settledAmount: -50_000,
            marginMode: 0,
            isoMarginAssetHash: bytes32(0)
        });

        // Expect SettlementExecutionV3 event
        vm.expectEmit(true, false, false, true);
        emit SettlementExecutionV3(
            SYMBOL_HASH_ETH_USDC,
            25_000_000,
            0,
            -50_000,
            0,
            bytes32(0)
        );

        // Expect SettlementResultV3 event (indexed: eventId=any, accountId=ALICE)
        vm.expectEmit(false, true, false, true);
        emit SettlementResultV3(
            0, // eventId: don't check (auto-incremented)
            ALICE,
            -50_000,
            TOKEN_HASH,
            bytes32(0),
            0,
            1, // settlementExecutionsCount
            11 // lastEngineEventId = eventId param
        );

        vm.prank(address(operatorManager));
        ledger.executeSettlementV3(
            EventTypes.SettlementV3({
                accountId: ALICE,
                settledAmount: -50_000,
                settledAssetHash: TOKEN_HASH,
                insuranceAccountId: bytes32(0),
                insuranceTransferAmount: 0,
                isoSettlementExecutions: execs,
                timestamp: 1678975214714
            }),
            11
        );
    }

    // Re-declare events for vm.expectEmit
    event SettlementExecutionV3(
        bytes32 indexed symbolHash,
        uint128 markPrice,
        int128 sumUnitaryFundings,
        int128 settledAmount,
        uint8 marginMode,
        bytes32 isoMarginAssetHash
    );

    event SettlementResultV3(
        uint64 indexed eventId,
        bytes32 indexed accountId,
        int128 settledAmount,
        bytes32 settledAssetHash,
        bytes32 insuranceAccountId,
        uint128 insuranceTransferAmount,
        uint64 settlementExecutionsCount,
        uint64 lastEngineEventId
    );
}
