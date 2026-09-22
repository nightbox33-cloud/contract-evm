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

contract MarginTransferV3Test is Test {
    bytes32 constant BROKER_HASH = 0x083098c593f395bea1de45dda552d9f14e8fcb0be3faaa7a1903c5477d7ba7fd;
    bytes32 constant TOKEN_HASH = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant SYMBOL_HASH_BTC_USDC = 0x1111101010101010101010101010101010101010101010101010101010101010;
    uint256 constant CHAIN_ID = 986532;
    bytes32 constant ALICE = 0xa11ce00000000000000000000000000000000000000000000000000000000000;

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

        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
    }

    // =================== Cross to Isolated ===================

    function test_marginTransferV3_cross_to_iso() public {
        // Set up iso position
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 500_000_000, 50_000_000, 0, 30_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 100_000_000);

        vm.prank(address(operatorManager));
        ledger.executeMarginTransferV3(
            EventTypes.MarginTransferV3({
                accountId: ALICE,
                marginFromCross: 200_000_000, // positive: cross -> iso
                transferAssetHash: TOKEN_HASH,
                isoSymbolHash: SYMBOL_HASH_BTC_USDC,
                timestamp: 1678975214714
            }),
            1
        );

        // Cross balance decreased
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 800_000_000); // 1B - 200M
        // Iso margin increased
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH), 300_000_000); // 100M + 200M
    }

    // =================== Isolated to Cross ===================

    function test_marginTransferV3_iso_to_cross() public {
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 500_000_000, 50_000_000, 0, 30_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 500_000_000);

        vm.prank(address(operatorManager));
        ledger.executeMarginTransferV3(
            EventTypes.MarginTransferV3({
                accountId: ALICE,
                marginFromCross: -300_000_000, // negative: iso -> cross
                transferAssetHash: TOKEN_HASH,
                isoSymbolHash: SYMBOL_HASH_BTC_USDC,
                timestamp: 1678975214714
            }),
            2
        );

        // Cross balance increased
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_300_000_000); // 1B + 300M
        // Iso margin decreased
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH), 200_000_000); // 500M - 300M
    }

    // =================== Zero transfer ===================

    function test_marginTransferV3_zero_amount() public {
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 500_000_000, 50_000_000, 0, 30_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 100_000_000);

        vm.prank(address(operatorManager));
        ledger.executeMarginTransferV3(
            EventTypes.MarginTransferV3({
                accountId: ALICE,
                marginFromCross: 0,
                transferAssetHash: TOKEN_HASH,
                isoSymbolHash: SYMBOL_HASH_BTC_USDC,
                timestamp: 1678975214714
            }),
            3
        );

        // Nothing changes
        assertEq(ledger.getUserLedgerBalance(ALICE, TOKEN_HASH), 1_000_000_000);
        assertEq(ledger.getIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH), 100_000_000);
    }

    // =================== Access control ===================

    function testRevert_marginTransferV3_only_operator_manager() public {
        vm.expectRevert(IError.OnlyOperatorCanCall.selector);
        ledger.executeMarginTransferV3(
            EventTypes.MarginTransferV3({
                accountId: ALICE,
                marginFromCross: 100_000_000,
                transferAssetHash: TOKEN_HASH,
                isoSymbolHash: SYMBOL_HASH_BTC_USDC,
                timestamp: 1678975214714
            }),
            4
        );
    }

    // =================== Event assertion ===================

    function test_marginTransferV3_emits_event() public {
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_BTC_USDC, 500_000_000, 50_000_000, 0, 30_000_000, 0, 0, 0, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_BTC_USDC, TOKEN_HASH, 100_000_000);

        // Expect MarginTransferV3 event (indexed: eventId=any, accountId=ALICE)
        vm.expectEmit(false, true, false, true);
        emit MarginTransferV3(
            0, // eventId: don't check
            ALICE,
            200_000_000, // transferAmount (marginFromCross)
            TOKEN_HASH,
            SYMBOL_HASH_BTC_USDC,
            1678975214714, // timestamp
            5 // lastEngineEventId
        );

        vm.prank(address(operatorManager));
        ledger.executeMarginTransferV3(
            EventTypes.MarginTransferV3({
                accountId: ALICE,
                marginFromCross: 200_000_000,
                transferAssetHash: TOKEN_HASH,
                isoSymbolHash: SYMBOL_HASH_BTC_USDC,
                timestamp: 1678975214714
            }),
            5
        );
    }

    // Re-declare event for vm.expectEmit
    event MarginTransferV3(
        uint64 indexed eventId,
        bytes32 indexed accountId,
        int128 transferAmount,
        bytes32 transferAssetHash,
        bytes32 isoSymbolHash,
        uint64 timestamp,
        uint64 lastEngineEventId
    );
}
