// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import "../../src/OperatorManager.sol";
import "../../src/OperatorManagerImplA.sol";
import "../../src/VaultManager.sol";
import "../../src/MarketManager.sol";
import "../../src/FeeManager.sol";
import "../mock/LedgerCrossChainManagerMock.sol";
import "../cheater/LedgerCheater.sol";
import "../../src/LedgerImplA.sol";
import "../../src/LedgerImplD.sol";

/// @title PerpTrade V4 tests
/// @notice V4 = V3 + `isInsuranceAccount` appended to every trade.
///   * isInsuranceAccount == false : state transition must be identical to V3 (field-by-field, incl. fuzz)
///   * isInsuranceAccount == true  : ONLY averageEntryPrice / openingCost are left untouched
///   * the engine signature covers the flag; batchId / count / operator / signer checks equal V3
contract PerpTradeUploadV4Test is Test {
    using ECDSA for bytes32;

    bytes32 constant BROKER_HASH = 0x083098c593f395bea1de45dda552d9f14e8fcb0be3faaa7a1903c5477d7ba7fd;
    bytes32 constant TOKEN_HASH = 0xd6aca1be9729c13d677335161321649cccae6a591554772516700f986f942eaa;
    bytes32 constant SYMBOL_HASH_ETH_USDC = 0x2222101010101010101010101010101010101010101010101010101010101010;
    uint256 constant CHAIN_ID = 986532;
    bytes32 constant ALICE = 0xa11ce00000000000000000000000000000000000000000000000000000000000;
    bytes32 constant INSURANCE_FUND = 0x1234123412341234123412341234123412341234123412341234123412341234;
    uint64 constant TS = 1678975214714;

    // engine perp trade upload signer (same test key as Signature.t.sol) + an unrelated key
    uint256 constant ENGINE_PK = 0xff965a6595be51798d16a8e3f4c10db72af43e2f65d27784a8f92fab1919fd15;
    uint256 constant OTHER_PK = 0x4f3edf983ac636a65a842ce7c78d9aa706d3b113bce036f9d6f235a491091696;

    ProxyAdmin admin;
    address constant operatorAddress = address(0x1234567890);
    LedgerCrossChainManagerMock ledgerCrossChainManager;
    OperatorManager operatorManager;
    IVaultManager vaultManager;
    LedgerCheater ledger;
    IFeeManager feeManager;
    IMarketManager marketManager;
    bytes32 feeCollector;

    // Re-declared for vm.expectEmit
    event ProcessValidatedFuturesV4(
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
        int128 isoMargin,
        bool isInsuranceAccount
    );
    event FuturesTradeUploadV4(uint64 indexed batchId);

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
        OperatorManagerImplA operatorManagerImplA = new OperatorManagerImplA();

        bytes memory initData = abi.encodeWithSignature("initialize()");
        TransparentUpgradeableProxy operatorProxy =
            new TransparentUpgradeableProxy(address(operatorManagerImpl), address(admin), initData);
        TransparentUpgradeableProxy vaultProxy =
            new TransparentUpgradeableProxy(address(vaultManagerImpl), address(admin), initData);
        TransparentUpgradeableProxy ledgerProxy =
            new TransparentUpgradeableProxy(address(ledgerImpl), address(admin), initData);
        TransparentUpgradeableProxy feeProxy = new TransparentUpgradeableProxy(address(feeImpl), address(admin), initData);
        TransparentUpgradeableProxy marketProxy =
            new TransparentUpgradeableProxy(address(marketImpl), address(admin), initData);

        operatorManager = OperatorManager(address(operatorProxy));
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
        operatorManager.setOperatorManagerImplA(address(operatorManagerImplA));
        operatorManager.setEnginePerpTradeUploadAddress(vm.addr(ENGINE_PK));

        vaultManager.setLedgerAddress(address(ledger));
        if (!vaultManager.getAllowedToken(TOKEN_HASH)) vaultManager.setAllowedToken(TOKEN_HASH, true);
        if (!vaultManager.getAllowedBroker(BROKER_HASH)) vaultManager.setAllowedBroker(BROKER_HASH, true);
        vaultManager.setAllowedChainToken(TOKEN_HASH, CHAIN_ID, true);
        if (!vaultManager.getAllowedSymbol(SYMBOL_HASH_ETH_USDC)) vaultManager.setAllowedSymbol(SYMBOL_HASH_ETH_USDC, true);

        feeManager.setLedgerAddress(address(ledger));
        marketManager.setOperatorManagerAddress(address(operatorManager));
        marketManager.setLedgerAddress(address(ledger));
        ledgerCrossChainManager.setLedger(address(ledger));
        ledgerCrossChainManager.setOperatorManager(address(operatorManager));

        feeCollector = feeManager.getFeeCollector(IFeeManager.FeeCollectorType.FuturesFeeCollector);
    }

    /*//////////////////////////////////////////////////////////////
                                helpers
    //////////////////////////////////////////////////////////////*/

    function _v3(
        bytes32 accountId,
        int128 tradeQty,
        int128 notional,
        uint128 executedPrice,
        int128 fee,
        int128 sumUnitaryFundings,
        uint64 tradeId,
        uint8 marginMode,
        int128 marginFromCross
    ) internal pure returns (PerpTypes.FuturesTradeUploadV3 memory) {
        return PerpTypes.FuturesTradeUploadV3({
            accountId: accountId,
            symbolHash: SYMBOL_HASH_ETH_USDC,
            feeAssetHash: TOKEN_HASH,
            tradeQty: tradeQty,
            notional: notional,
            executedPrice: executedPrice,
            fee: fee,
            sumUnitaryFundings: sumUnitaryFundings,
            tradeId: tradeId,
            matchId: 100,
            timestamp: TS,
            side: tradeQty < 0,
            marginMode: marginMode,
            isoMarginAssetHash: marginMode == 1 ? TOKEN_HASH : bytes32(0),
            marginFromCross: marginFromCross
        });
    }

    function _toV4(PerpTypes.FuturesTradeUploadV3 memory t, bool isInsuranceAccount)
        internal
        pure
        returns (PerpTypes.FuturesTradeUploadV4 memory)
    {
        return PerpTypes.FuturesTradeUploadV4({
            accountId: t.accountId,
            symbolHash: t.symbolHash,
            feeAssetHash: t.feeAssetHash,
            tradeQty: t.tradeQty,
            notional: t.notional,
            executedPrice: t.executedPrice,
            fee: t.fee,
            sumUnitaryFundings: t.sumUnitaryFundings,
            tradeId: t.tradeId,
            matchId: t.matchId,
            timestamp: t.timestamp,
            side: t.side,
            marginMode: t.marginMode,
            isoMarginAssetHash: t.isoMarginAssetHash,
            marginFromCross: t.marginFromCross,
            isInsuranceAccount: isInsuranceAccount
        });
    }

    function _runV3(PerpTypes.FuturesTradeUploadV3 memory t) internal returns (bool ok) {
        vm.prank(address(operatorManager));
        try ledger.executeProcessValidatedFuturesV3(t) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    function _runV4(PerpTypes.FuturesTradeUploadV4 memory t) internal returns (bool ok) {
        vm.prank(address(operatorManager));
        try ledger.executeProcessValidatedFuturesV4(t) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    struct CrossSnap {
        AccountTypes.PerpPosition pos;
        int128 balance;
        uint64 lastPerpTradeId;
        AccountTypes.PerpPosition feePos;
        uint64 feeLastPerpTradeId;
    }

    struct IsoSnap {
        AccountTypes.PerpPosition pos; // iso scalar fields packed in PerpPosition shape
        int128 margin;
        int128 balance;
        uint64 lastPerpTradeId;
        AccountTypes.PerpPosition feePos;
        uint64 feeLastPerpTradeId;
    }

    function _crossSnap(bytes32 acc) internal view returns (CrossSnap memory s) {
        s.pos = ledger.getPerpPosition(acc, SYMBOL_HASH_ETH_USDC);
        s.balance = ledger.getUserLedgerBalance(acc, TOKEN_HASH);
        s.lastPerpTradeId = ledger.getLastPerpTradeId(acc);
        s.feePos = ledger.getPerpPosition(feeCollector, SYMBOL_HASH_ETH_USDC);
        s.feeLastPerpTradeId = ledger.getLastPerpTradeId(feeCollector);
    }

    function _isoSnap(bytes32 acc) internal view returns (IsoSnap memory s) {
        s.pos = ledger.getIsoPerpPositionAsPerp(acc, SYMBOL_HASH_ETH_USDC);
        s.margin = ledger.getIsoMargin(acc, SYMBOL_HASH_ETH_USDC, TOKEN_HASH);
        s.balance = ledger.getUserLedgerBalance(acc, TOKEN_HASH);
        s.lastPerpTradeId = ledger.getLastPerpTradeId(acc);
        s.feePos = ledger.getPerpPosition(feeCollector, SYMBOL_HASH_ETH_USDC);
        s.feeLastPerpTradeId = ledger.getLastPerpTradeId(feeCollector);
    }

    function _assertPosEq(AccountTypes.PerpPosition memory a, AccountTypes.PerpPosition memory b, string memory tag)
        internal
    {
        assertEq(a.positionQty, b.positionQty, string.concat(tag, ".positionQty"));
        assertEq(a.costPosition, b.costPosition, string.concat(tag, ".costPosition"));
        assertEq(a.lastSumUnitaryFundings, b.lastSumUnitaryFundings, string.concat(tag, ".lastSumUnitaryFundings"));
        assertEq(a.lastExecutedPrice, b.lastExecutedPrice, string.concat(tag, ".lastExecutedPrice"));
        assertEq(a.lastSettledPrice, b.lastSettledPrice, string.concat(tag, ".lastSettledPrice"));
        assertEq(a.averageEntryPrice, b.averageEntryPrice, string.concat(tag, ".averageEntryPrice"));
        assertEq(a.openingCost, b.openingCost, string.concat(tag, ".openingCost"));
        assertEq(a.lastAdlPrice, b.lastAdlPrice, string.concat(tag, ".lastAdlPrice"));
    }

    function _assertCrossSnapEq(CrossSnap memory a, CrossSnap memory b) internal {
        _assertPosEq(a.pos, b.pos, "pos");
        assertEq(a.balance, b.balance, "balance");
        assertEq(a.lastPerpTradeId, b.lastPerpTradeId, "lastPerpTradeId");
        _assertPosEq(a.feePos, b.feePos, "feePos");
        assertEq(a.feeLastPerpTradeId, b.feeLastPerpTradeId, "feeLastPerpTradeId");
    }

    function _assertIsoSnapEq(IsoSnap memory a, IsoSnap memory b) internal {
        _assertPosEq(a.pos, b.pos, "iso");
        assertEq(a.margin, b.margin, "iso.margin");
        assertEq(a.balance, b.balance, "balance");
        assertEq(a.lastPerpTradeId, b.lastPerpTradeId, "lastPerpTradeId");
        _assertPosEq(a.feePos, b.feePos, "feePos");
        assertEq(a.feeLastPerpTradeId, b.feeLastPerpTradeId, "feeLastPerpTradeId");
    }

    function _seedCross(bytes32 acc, int128 qty, int128 cost, int128 lastFunding, uint128 avg, int128 openingCost)
        internal
    {
        ledger.cheatSetUserPosition(
            acc,
            SYMBOL_HASH_ETH_USDC,
            AccountTypes.PerpPosition({
                positionQty: qty,
                costPosition: cost,
                lastSumUnitaryFundings: lastFunding,
                lastExecutedPrice: 250_000_000,
                lastSettledPrice: 0,
                averageEntryPrice: avg,
                openingCost: openingCost,
                lastAdlPrice: 0
            })
        );
    }

    /// @dev V4(false) must behave exactly like V3 (same success/revert, same resulting state)
    function _assertV4FalseEqualsV3Cross(PerpTypes.FuturesTradeUploadV3 memory t) internal {
        uint256 snap = vm.snapshot();
        bool ok3 = _runV3(t);
        CrossSnap memory s3 = _crossSnap(t.accountId);
        vm.revertTo(snap);
        bool ok4 = _runV4(_toV4(t, false));
        assertEq(ok4, ok3, "V4(false) must succeed/revert exactly like V3");
        if (!ok3) return;
        _assertCrossSnapEq(_crossSnap(t.accountId), s3);
    }

    function _assertV4FalseEqualsV3Iso(PerpTypes.FuturesTradeUploadV3 memory t) internal {
        uint256 snap = vm.snapshot();
        bool ok3 = _runV3(t);
        IsoSnap memory s3 = _isoSnap(t.accountId);
        vm.revertTo(snap);
        bool ok4 = _runV4(_toV4(t, false));
        assertEq(ok4, ok3, "V4(false) must succeed/revert exactly like V3");
        if (!ok3) return;
        _assertIsoSnapEq(_isoSnap(t.accountId), s3);
    }

    /// @dev V4(true): avg/openingCost untouched, everything else identical to V3 (when V3 succeeds)
    function _assertV4TrueSkipsAvgOnlyCross(PerpTypes.FuturesTradeUploadV3 memory t) internal {
        CrossSnap memory s0 = _crossSnap(t.accountId);
        uint256 snap = vm.snapshot();
        bool ok3 = _runV3(t);
        CrossSnap memory s3 = _crossSnap(t.accountId);
        vm.revertTo(snap);
        assertTrue(_runV4(_toV4(t, true)), "V4(true) must not revert");
        CrossSnap memory s4 = _crossSnap(t.accountId);
        assertEq(s4.pos.averageEntryPrice, s0.pos.averageEntryPrice, "avg must be untouched");
        assertEq(s4.pos.openingCost, s0.pos.openingCost, "openingCost must be untouched");
        if (!ok3) return;
        s3.pos.averageEntryPrice = s0.pos.averageEntryPrice;
        s3.pos.openingCost = s0.pos.openingCost;
        _assertCrossSnapEq(s4, s3);
    }

    function _assertV4TrueSkipsAvgOnlyIso(PerpTypes.FuturesTradeUploadV3 memory t) internal {
        IsoSnap memory s0 = _isoSnap(t.accountId);
        uint256 snap = vm.snapshot();
        bool ok3 = _runV3(t);
        IsoSnap memory s3 = _isoSnap(t.accountId);
        vm.revertTo(snap);
        assertTrue(_runV4(_toV4(t, true)), "V4(true) must not revert");
        IsoSnap memory s4 = _isoSnap(t.accountId);
        assertEq(s4.pos.averageEntryPrice, s0.pos.averageEntryPrice, "iso avg must be untouched");
        assertEq(s4.pos.openingCost, s0.pos.openingCost, "iso openingCost must be untouched");
        if (!ok3) return;
        s3.pos.averageEntryPrice = s0.pos.averageEntryPrice;
        s3.pos.openingCost = s0.pos.openingCost;
        _assertIsoSnapEq(s4, s3);
    }

    /// @dev map an arbitrary uint into [-m, m]
    function _sym(uint256 x, int128 m) internal pure returns (int128) {
        uint256 span = uint256(uint128(m)) * 2 + 1;
        return int128(int256(x % span)) - m;
    }

    /*//////////////////////////////////////////////////////////////
                    Ledger level: V4(false) == V3
    //////////////////////////////////////////////////////////////*/

    function test_v4_flagFalse_cross_open_matches_v3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _assertV4FalseEqualsV3Cross(_v3(ALICE, 200_000_000, 5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 1, 0, 0));
    }

    function test_v4_flagFalse_cross_reduce_with_funding_matches_v3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _seedCross(ALICE, 200_000_000, 5_000_000, 1_000_000_000_000_000, 250_000_000, -5_000_000);
        _assertV4FalseEqualsV3Cross(
            _v3(ALICE, -50_000_000, -1_300_000, 260_000_000, 5_000, 1_100_000_000_000_000, 7, 0, 0)
        );
    }

    function test_v4_flagFalse_cross_flip_matches_v3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _seedCross(ALICE, 200_000_000, 5_000_000, 1_000_000_000_000_000, 250_000_000, -5_000_000);
        _assertV4FalseEqualsV3Cross(
            _v3(ALICE, -300_000_000, -7_800_000, 260_000_000, 5_000, 1_000_000_000_000_000, 8, 0, 0)
        );
    }

    function test_v4_flagFalse_cross_close_matches_v3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _seedCross(ALICE, 200_000_000, 5_000_000, 1_000_000_000_000_001, 250_000_000, -5_000_000);
        _assertV4FalseEqualsV3Cross(
            _v3(ALICE, -200_000_000, -5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 2, 0, 0)
        );
    }

    function test_v4_flagFalse_iso_open_matches_v3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _assertV4FalseEqualsV3Iso(
            _v3(ALICE, 100_000_000, 2_500_000, 250_000_000, 3_000, 1_000_000_000_000_001, 1, 1, 500_000_000)
        );
    }

    function test_v4_flagFalse_iso_reduce_negative_margin_matches_v3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserIsoPosition(
            ALICE, SYMBOL_HASH_ETH_USDC, 100_000_000, 2_500_000, 1_000_000_000_000_001, 250_000_000, 0, 250_000_000, -2_500_000, 0
        );
        ledger.cheatSetUserIsoMargin(ALICE, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 500_000_000);
        _assertV4FalseEqualsV3Iso(
            _v3(ALICE, -50_000_000, -1_250_000, 250_000_000, 1_500, 1_000_000_000_000_001, 2, 1, -200_000_000)
        );
    }

    /// @dev V3 does not reject unknown marginMode (no position touched, lastPerpTradeId still updated); V4 must mirror it
    function test_v4_flagFalse_unknown_marginMode_matches_v3() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        PerpTypes.FuturesTradeUploadV3 memory t = _v3(ALICE, 100_000_000, 2_500_000, 250_000_000, 0, 0, 42, 2, 0);
        _assertV4FalseEqualsV3Cross(t);
        _assertV4FalseEqualsV3Iso(t);
        assertEq(ledger.getLastPerpTradeId(ALICE), 42);
        assertEq(ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC).positionQty, 0);
    }

    function test_v4_flagFalse_revert_symbol_not_allowed_matches_v3() public {
        PerpTypes.FuturesTradeUploadV3 memory t = _v3(ALICE, 100_000_000, 2_500_000, 250_000_000, 0, 0, 1, 0, 0);
        t.symbolHash = 0x9999999999999999999999999999999999999999999999999999999999999999;
        vm.prank(address(operatorManager));
        vm.expectRevert(IError.SymbolNotAllowed.selector);
        ledger.executeProcessValidatedFuturesV4(_toV4(t, false));
        vm.prank(address(operatorManager));
        vm.expectRevert(IError.SymbolNotAllowed.selector);
        ledger.executeProcessValidatedFuturesV4(_toV4(t, true));
    }

    function testRevert_v4_only_operator_manager() public {
        PerpTypes.FuturesTradeUploadV3 memory t = _v3(ALICE, 100_000_000, 2_500_000, 250_000_000, 0, 0, 1, 0, 0);
        vm.expectRevert(IError.OnlyOperatorCanCall.selector);
        ledger.executeProcessValidatedFuturesV4(_toV4(t, false));
    }

    function test_v4_calls_marketManager_setLastFundingUpdated() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        PerpTypes.FuturesTradeUploadV3 memory t = _v3(ALICE, 100_000_000, 2_500_000, 250_000_000, 0, 0, 1, 0, 0);
        vm.expectCall(
            address(marketManager),
            abi.encodeCall(IMarketManager.setLastFundingUpdated, (SYMBOL_HASH_ETH_USDC, TS))
        );
        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV4(_toV4(t, true));
    }

    /*//////////////////////////////////////////////////////////////
                Ledger level: V4(true) skips avg/openingCost only
    //////////////////////////////////////////////////////////////*/

    function test_v4_flagTrue_cross_open_skips_avg_only() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _assertV4TrueSkipsAvgOnlyCross(
            _v3(INSURANCE_FUND, 200_000_000, 5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 1, 0, 0)
        );
        // avg stays at its initial (zero) value even though a position was opened
        AccountTypes.PerpPosition memory p = ledger.getPerpPosition(INSURANCE_FUND, SYMBOL_HASH_ETH_USDC);
        assertEq(p.positionQty, 200_000_000);
        assertEq(p.costPosition, 5_005_000);
        assertEq(p.averageEntryPrice, 0);
        assertEq(p.openingCost, 0);
    }

    function test_v4_flagTrue_cross_reduce_skips_avg_only() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _seedCross(INSURANCE_FUND, 200_000_000, 5_000_000, 1_000_000_000_000_000, 250_000_000, -5_000_000);
        _assertV4TrueSkipsAvgOnlyCross(
            _v3(INSURANCE_FUND, -50_000_000, -1_300_000, 260_000_000, 5_000, 1_100_000_000_000_000, 7, 0, 0)
        );
    }

    function test_v4_flagTrue_cross_close_keeps_stale_avg() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _seedCross(INSURANCE_FUND, 200_000_000, 5_000_000, 1_000_000_000_000_001, 250_000_000, -5_000_000);
        _assertV4TrueSkipsAvgOnlyCross(
            _v3(INSURANCE_FUND, -200_000_000, -5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 2, 0, 0)
        );
        AccountTypes.PerpPosition memory p = ledger.getPerpPosition(INSURANCE_FUND, SYMBOL_HASH_ETH_USDC);
        assertEq(p.positionQty, 0, "closed");
        // documented: V3 would reset avg/openingCost to 0 on full close, V4(true) leaves the stale values
        assertEq(p.averageEntryPrice, 250_000_000);
        assertEq(p.openingCost, -5_000_000);
    }

    function test_v4_flagTrue_iso_open_skips_avg_only() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _assertV4TrueSkipsAvgOnlyIso(
            _v3(INSURANCE_FUND, 100_000_000, 2_500_000, 250_000_000, 3_000, 1_000_000_000_000_001, 1, 1, 500_000_000)
        );
        // isolated margin transfer still happened
        assertEq(ledger.getUserLedgerBalance(INSURANCE_FUND, TOKEN_HASH), 500_000_000);
        assertEq(ledger.getIsoMargin(INSURANCE_FUND, SYMBOL_HASH_ETH_USDC, TOKEN_HASH), 500_000_000);
    }

    function test_v4_flagTrue_iso_reduce_skips_avg_only() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserIsoPosition(
            INSURANCE_FUND, SYMBOL_HASH_ETH_USDC, 100_000_000, 2_500_000, 1_000_000_000_000_001, 250_000_000, 0, 250_000_000, -2_500_000, 0
        );
        ledger.cheatSetUserIsoMargin(INSURANCE_FUND, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 500_000_000);
        _assertV4TrueSkipsAvgOnlyIso(
            _v3(INSURANCE_FUND, -50_000_000, -1_250_000, 250_000_000, 1_500, 1_100_000_000_000_001, 2, 1, 0)
        );
    }

    /// @dev The production incident input (see hotfix/skip-calavg-for-listed-accounts): V3 reverts with
    ///      SafeCastUnderflow while recomputing the average entry price. V4(false) must revert identically,
    ///      V4(true) must apply the trade.
    function test_v4_flagTrue_applies_trade_where_v3_underflows() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _seedCross(INSURANCE_FUND, -329_700_000, -70_000_000_000, 0, 0, -30_976_563_000);
        PerpTypes.FuturesTradeUploadV3 memory t =
            _v3(INSURANCE_FUND, -76_000_000, -166_090_400, 21_854_000_000, 12_000, 0, 99, 0, 0);

        vm.prank(address(operatorManager));
        vm.expectRevert(SafeCastHelper.SafeCastUnderflow.selector);
        ledger.executeProcessValidatedFuturesV3(t);

        vm.prank(address(operatorManager));
        vm.expectRevert(SafeCastHelper.SafeCastUnderflow.selector);
        ledger.executeProcessValidatedFuturesV4(_toV4(t, false));

        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV4(_toV4(t, true));

        AccountTypes.PerpPosition memory p = ledger.getPerpPosition(INSURANCE_FUND, SYMBOL_HASH_ETH_USDC);
        assertEq(p.positionQty, -329_700_000 - 76_000_000, "qty applied");
        assertEq(p.costPosition, -70_000_000_000 - 166_090_400 + 12_000, "cost = old + notional + fee");
        assertEq(p.lastExecutedPrice, 21_854_000_000);
        assertEq(p.averageEntryPrice, 0, "avg untouched");
        assertEq(p.openingCost, -30_976_563_000, "openingCost untouched");
        assertEq(ledger.getLastPerpTradeId(INSURANCE_FUND), 99);
        // fee still routed to the fee collector
        assertEq(ledger.getPerpPosition(feeCollector, SYMBOL_HASH_ETH_USDC).costPosition, -12_000);
    }

    function test_v4_emits_ProcessValidatedFuturesV4() public {
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        PerpTypes.FuturesTradeUploadV3 memory t =
            _v3(INSURANCE_FUND, 200_000_000, 5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 1, 0, 0);
        vm.expectEmit(true, true, false, true);
        emit ProcessValidatedFuturesV4(
            INSURANCE_FUND,
            SYMBOL_HASH_ETH_USDC,
            TOKEN_HASH,
            200_000_000,
            5_000_000,
            250_000_000,
            5_000,
            1_000_000_000_000_001,
            1,
            100,
            false,
            0,
            bytes32(0),
            int128(0),
            true
        );
        vm.prank(address(operatorManager));
        ledger.executeProcessValidatedFuturesV4(_toV4(t, true));
    }

    /*//////////////////////////////////////////////////////////////
                                fuzz
    //////////////////////////////////////////////////////////////*/

    struct FuzzIn {
        uint256 posQty0;
        uint256 openingCost0;
        uint256 tradeQty;
        uint256 notional;
        uint256 price;
        uint256 fee;
        uint256 extra; // funding delta (cross) / marginFromCross (iso)
    }

    function _fuzzSeedCross(bytes32 acc, FuzzIn memory f) internal {
        ledger.cheatDeposit(acc, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        _seedCross(
            acc,
            _sym(f.posQty0, 1_000_000_000),
            _sym(f.posQty0 / 7, 10_000_000_000),
            1_000_000_000_000_000,
            uint128(f.price % 1e12),
            _sym(f.openingCost0, 100_000_000_000)
        );
    }

    function _fuzzSeedIso(bytes32 acc, FuzzIn memory f) internal {
        ledger.cheatDeposit(acc, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatSetUserIsoPosition(
            acc,
            SYMBOL_HASH_ETH_USDC,
            _sym(f.posQty0, 1_000_000_000),
            _sym(f.posQty0 / 7, 10_000_000_000),
            1_000_000_000_000_000,
            250_000_000,
            0,
            uint128(f.price % 1e12),
            _sym(f.openingCost0, 100_000_000_000),
            0
        );
        ledger.cheatSetUserIsoMargin(acc, SYMBOL_HASH_ETH_USDC, TOKEN_HASH, 100_000_000);
    }

    function _fuzzTrade(bytes32 acc, FuzzIn memory f, uint8 marginMode)
        internal
        pure
        returns (PerpTypes.FuturesTradeUploadV3 memory t)
    {
        t = _v3(
            acc,
            _sym(f.tradeQty, 1_000_000_000),
            _sym(f.notional, 100_000_000_000),
            uint128(1 + f.price % 1e12),
            int128(int256(f.fee % 1_000_000)),
            marginMode == 0 ? 1_000_000_000_000_000 + _sym(f.extra, 1e15) : int128(1_100_000_000_000_000),
            uint64(1 + f.tradeQty % 1000),
            marginMode,
            marginMode == 1 ? _sym(f.extra, 500_000_000) : int128(0)
        );
    }

    function testFuzz_v4_flagFalse_equals_v3_cross(FuzzIn memory f) public {
        vm.assume(_sym(f.tradeQty, 1_000_000_000) != 0);
        _fuzzSeedCross(ALICE, f);
        _assertV4FalseEqualsV3Cross(_fuzzTrade(ALICE, f, 0));
    }

    function testFuzz_v4_flagFalse_equals_v3_iso(FuzzIn memory f) public {
        vm.assume(_sym(f.tradeQty, 1_000_000_000) != 0);
        _fuzzSeedIso(ALICE, f);
        _assertV4FalseEqualsV3Iso(_fuzzTrade(ALICE, f, 1));
    }

    function testFuzz_v4_flagTrue_only_avg_differs_cross(FuzzIn memory f) public {
        vm.assume(_sym(f.tradeQty, 1_000_000_000) != 0);
        _fuzzSeedCross(INSURANCE_FUND, f);
        _assertV4TrueSkipsAvgOnlyCross(_fuzzTrade(INSURANCE_FUND, f, 0));
    }

    function testFuzz_v4_flagTrue_only_avg_differs_iso(FuzzIn memory f) public {
        vm.assume(_sym(f.tradeQty, 1_000_000_000) != 0);
        _fuzzSeedIso(INSURANCE_FUND, f);
        _assertV4TrueSkipsAvgOnlyIso(_fuzzTrade(INSURANCE_FUND, f, 1));
    }

    /*//////////////////////////////////////////////////////////////
            OperatorManager level: signature / batchId / count / operator
    //////////////////////////////////////////////////////////////*/

    function _batchV4(uint64 batchId, PerpTypes.FuturesTradeUploadV4[] memory trades)
        internal
        pure
        returns (PerpTypes.FuturesTradeUploadDataV4 memory d)
    {
        d.batchId = batchId;
        d.count = uint8(trades.length);
        d.trades = trades;
    }

    function _signV4(PerpTypes.FuturesTradeUploadDataV4 memory d, uint256 pk)
        internal
        returns (PerpTypes.FuturesTradeUploadDataV4 memory)
    {
        bytes32 h = keccak256(abi.encode(d.batchId, d.count, d.trades)).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        d.r = r;
        d.s = s;
        d.v = v;
        return d;
    }

    function _twoTrades() internal pure returns (PerpTypes.FuturesTradeUploadV4[] memory trades) {
        trades = new PerpTypes.FuturesTradeUploadV4[](2);
        trades[0] = _toV4(_v3(ALICE, 200_000_000, 5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 1, 0, 0), false);
        trades[1] =
            _toV4(_v3(INSURANCE_FUND, -200_000_000, -5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 2, 0, 0), true);
    }

    function test_om_v4_upload_success() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        assertEq(operatorManager.futuresUploadBatchId(), 1);

        PerpTypes.FuturesTradeUploadDataV4 memory d = _signV4(_batchV4(1, _twoTrades()), ENGINE_PK);

        vm.warp(1_700_000_000);
        vm.expectEmit(true, false, false, true);
        emit FuturesTradeUploadV4(1);
        vm.prank(operatorAddress);
        operatorManager.futuresTradeUploadV4(d);

        assertEq(operatorManager.futuresUploadBatchId(), 2, "batchId advanced");
        assertEq(operatorManager.lastOperatorInteraction(), 1_700_000_000, "ping recorded");

        AccountTypes.PerpPosition memory a = ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC);
        assertEq(a.positionQty, 200_000_000);
        assertEq(a.averageEntryPrice, 250_000_000, "flag=false: avg computed");
        AccountTypes.PerpPosition memory i = ledger.getPerpPosition(INSURANCE_FUND, SYMBOL_HASH_ETH_USDC);
        assertEq(i.positionQty, -200_000_000);
        assertEq(i.averageEntryPrice, 0, "flag=true: avg skipped");
        assertEq(i.costPosition, -5_000_000 + 5_000);
        assertEq(ledger.getLastPerpTradeId(INSURANCE_FUND), 2);
    }

    function testRevert_om_v4_wrong_signer() public {
        PerpTypes.FuturesTradeUploadDataV4 memory d = _signV4(_batchV4(1, _twoTrades()), OTHER_PK);
        vm.prank(operatorAddress);
        vm.expectRevert(IError.SignatureNotMatch.selector);
        operatorManager.futuresTradeUploadV4(d);
    }

    /// @dev the isInsuranceAccount flag is part of the signed payload: flipping it after signing must fail
    function testRevert_om_v4_tampered_flag() public {
        PerpTypes.FuturesTradeUploadDataV4 memory d = _signV4(_batchV4(1, _twoTrades()), ENGINE_PK);
        d.trades[0].isInsuranceAccount = true;
        vm.prank(operatorAddress);
        vm.expectRevert(IError.SignatureNotMatch.selector);
        operatorManager.futuresTradeUploadV4(d);
    }

    /// @dev a V3 signature over the same trade fields cannot be reused for V4 (encoding differs)
    function testRevert_om_v4_replay_v3_signature() public {
        PerpTypes.FuturesTradeUploadV4[] memory t4 = _twoTrades();
        t4[1].isInsuranceAccount = false;
        PerpTypes.FuturesTradeUploadV3[] memory t3 = new PerpTypes.FuturesTradeUploadV3[](2);
        t3[0] = _v3(ALICE, 200_000_000, 5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 1, 0, 0);
        t3[1] = _v3(INSURANCE_FUND, -200_000_000, -5_000_000, 250_000_000, 5_000, 1_000_000_000_000_001, 2, 0, 0);
        bytes32 h3 = keccak256(abi.encode(uint64(1), uint8(2), t3)).toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ENGINE_PK, h3);

        PerpTypes.FuturesTradeUploadDataV4 memory d = _batchV4(1, t4);
        d.r = r;
        d.s = s;
        d.v = v;
        vm.prank(operatorAddress);
        vm.expectRevert(IError.SignatureNotMatch.selector);
        operatorManager.futuresTradeUploadV4(d);
    }

    function testRevert_om_v4_batchId_mismatch() public {
        PerpTypes.FuturesTradeUploadDataV4 memory d = _signV4(_batchV4(5, _twoTrades()), ENGINE_PK);
        vm.prank(operatorAddress);
        vm.expectRevert(abi.encodeWithSelector(IError.BatchIdNotMatch.selector, uint64(5), uint64(1)));
        operatorManager.futuresTradeUploadV4(d);
    }

    function testRevert_om_v4_count_mismatch() public {
        PerpTypes.FuturesTradeUploadDataV4 memory d = _batchV4(1, _twoTrades());
        d.count = 3;
        d = _signV4(d, ENGINE_PK);
        vm.prank(operatorAddress);
        vm.expectRevert(abi.encodeWithSelector(IError.CountNotMatch.selector, uint256(2), uint256(3)));
        operatorManager.futuresTradeUploadV4(d);
    }

    function testRevert_om_v4_not_operator() public {
        PerpTypes.FuturesTradeUploadDataV4 memory d = _signV4(_batchV4(1, _twoTrades()), ENGINE_PK);
        vm.prank(address(0xBEEF));
        vm.expectRevert(IError.OnlyOperatorCanCall.selector);
        operatorManager.futuresTradeUploadV4(d);
    }

    function testRevert_om_v4_same_batch_replay() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        PerpTypes.FuturesTradeUploadDataV4 memory d = _signV4(_batchV4(1, _twoTrades()), ENGINE_PK);
        vm.prank(operatorAddress);
        operatorManager.futuresTradeUploadV4(d);
        vm.prank(operatorAddress);
        vm.expectRevert(abi.encodeWithSelector(IError.BatchIdNotMatch.selector, uint64(1), uint64(2)));
        operatorManager.futuresTradeUploadV4(d);
    }

    /// @dev V3 and V4 share futuresUploadBatchId; V3 keeps working after V4 is added
    function test_om_v3_and_v4_share_batch_counter() public {
        ledger.cheatDeposit(ALICE, TOKEN_HASH, 1_000_000_000, CHAIN_ID);
        ledger.cheatDeposit(INSURANCE_FUND, TOKEN_HASH, 1_000_000_000, CHAIN_ID);

        // batch 1: V3
        PerpTypes.FuturesTradeUploadV3[] memory t3 = new PerpTypes.FuturesTradeUploadV3[](1);
        t3[0] = _v3(ALICE, 100_000_000, 2_500_000, 250_000_000, 1_000, 1_000_000_000_000_001, 1, 0, 0);
        PerpTypes.FuturesTradeUploadDataV3 memory d3 =
            PerpTypes.FuturesTradeUploadDataV3({r: 0, s: 0, v: 0, batchId: 1, count: 1, trades: t3});
        {
            bytes32 h = keccak256(abi.encode(d3.batchId, d3.count, d3.trades)).toEthSignedMessageHash();
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ENGINE_PK, h);
            d3.r = r;
            d3.s = s;
            d3.v = v;
        }
        vm.prank(operatorAddress);
        operatorManager.futuresTradeUploadV3(d3);
        assertEq(operatorManager.futuresUploadBatchId(), 2);

        // batch 2: V4
        PerpTypes.FuturesTradeUploadDataV4 memory d4 = _signV4(_batchV4(2, _twoTrades()), ENGINE_PK);
        vm.prank(operatorAddress);
        operatorManager.futuresTradeUploadV4(d4);
        assertEq(operatorManager.futuresUploadBatchId(), 3);

        // batch 3: V3 with stale batchId rejected, correct one accepted
        vm.prank(operatorAddress);
        vm.expectRevert(abi.encodeWithSelector(IError.BatchIdNotMatch.selector, uint64(1), uint64(3)));
        operatorManager.futuresTradeUploadV3(d3);

        assertEq(ledger.getPerpPosition(ALICE, SYMBOL_HASH_ETH_USDC).positionQty, 300_000_000);
    }
}
