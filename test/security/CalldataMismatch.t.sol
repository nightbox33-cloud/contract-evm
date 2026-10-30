// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import "../../src/OperatorManager.sol";
import "../../src/OperatorManagerImplB.sol";
import "../../src/library/Signature.sol";

/// @notice AUDIT C-01 - calldata/signature mismatch in `_processEventUpload`.
///
/// `Signature.eventsUploadEncodeHash` decodes the event blob with `abi.decode(blob, (T))`,
/// which HONOURS the leading ABI head offset, while `OperatorManagerImplB._processEventUpload`
/// always strips exactly 32 bytes and splices the tail into the Ledger calldata. A payload
/// `X ++ evilBody ++ signedBody` (with `X == 32 + evilBody.length`) therefore hashes as
/// `signedBody` for the engine signature but executes as `evilBody` on the Ledger.
contract MockLedger {
    bytes32 public lastAccountId;
    int128 public lastSettledAmount;
    uint64 public lastEventId;

    function executeSettlement(EventTypes.Settlement calldata s, uint64 eventId) external {
        lastAccountId = s.accountId;
        lastSettledAmount = s.settledAmount;
        lastEventId = eventId;
    }
}

contract CalldataMismatchTest is Test {
    OperatorManager internal om;
    MockLedger internal mockLedger;
    ProxyAdmin internal admin;

    uint256 internal constant ENGINE_PK = 0xA11CE;
    address internal engine;

    bytes32 internal constant ASSET = bytes32(uint256(0xA55E7));
    bytes32 internal constant INSURANCE = bytes32(uint256(0x1F5));
    bytes32 internal constant SIGNED_ACCOUNT = bytes32(uint256(0x1111));
    bytes32 internal constant ATTACKER_ACCOUNT = bytes32(uint256(0x9999));
    bytes32 internal constant SYMBOL = bytes32(uint256(0x5B1));
    uint64 internal constant EVENT_ID = 7;

    function setUp() public {
        engine = vm.addr(ENGINE_PK);
        admin = new ProxyAdmin();
        OperatorManager impl = new OperatorManager();
        om = OperatorManager(address(new TransparentUpgradeableProxy(address(impl), address(admin), "")));
        om.initialize(); // owner = address(this), eventUploadBatchId = 1

        OperatorManagerImplB implB = new OperatorManagerImplB();
        om.setOperatorManagerImplB(address(implB));
        om.initBizTypeToSelector();
        om.setEngineEventUploadAddress(engine);
        mockLedger = new MockLedger();
        om.setLedger(address(mockLedger));
        om.setOperator(address(this));
    }

    // ---------------------------------------------------------------------
    // 1. The two decoders really do read two different structs out of one blob
    // ---------------------------------------------------------------------
    function test_decodersDivergeOnNonCanonicalOffset() public {
        EventTypes.Settlement memory signedSettlement = _settlement(SIGNED_ACCOUNT, 1);
        EventTypes.Settlement memory evilSettlement = _settlement(ATTACKER_ACCOUNT, 1_000_000e6);

        bytes memory blob = _forgeBlob(signedSettlement, evilSettlement);

        // what `eventsUploadEncodeHash` hashes: the benign struct ...
        EventTypes.Settlement memory asDecodedByEngine = abi.decode(blob, (EventTypes.Settlement));
        assertEq(asDecodedByEngine.accountId, SIGNED_ACCOUNT);
        assertEq(asDecodedByEngine.settledAmount, 1);

        // ... and what the Ledger decodes once `_processEventUpload` pasted `blob[32:]` in:
        EventTypes.Settlement memory asDecodedByLedger = abi.decode(_tail(blob, 32), (EventTypes.Settlement));
        assertEq(asDecodedByLedger.accountId, ATTACKER_ACCOUNT);
        assertEq(asDecodedByLedger.settledAmount, 1_000_000e6);
    }

    // ---------------------------------------------------------------------
    // 2. The engine signature still validates over the forged payload
    // ---------------------------------------------------------------------
    function test_engineSignatureValidOverForgedPayload() public {
        EventTypes.EventUpload memory data = _forgedUpload();
        assertTrue(_verify(data), "engine signature must still verify");
    }

    // ---------------------------------------------------------------------
    // 3. Post-fix: the forged payload is rejected, the canonical one still works
    // ---------------------------------------------------------------------
    function test_rejectsNonCanonicalOffset() public {
        EventTypes.EventUpload memory data = _forgedUpload();
        vm.expectRevert(bytes("NonCanonicalDataOffset"));
        om.eventUpload(data);
    }

    function test_canonicalPayloadStillExecutes() public {
        EventTypes.EventUploadData[] memory events = new EventTypes.EventUploadData[](1);
        events[0] = EventTypes.EventUploadData({
            bizType: uint8(Signature.BizType.Settlement),
            eventId: EVENT_ID,
            data: abi.encode(_settlement(SIGNED_ACCOUNT, 1))
        });
        EventTypes.EventUpload memory data =
            _sign(EventTypes.EventUpload({batchId: om.eventUploadBatchId(), count: 1, events: events, r: 0, s: 0, v: 0}));

        om.eventUpload(data);
        assertEq(mockLedger.lastAccountId(), SIGNED_ACCOUNT);
        assertEq(mockLedger.lastSettledAmount(), 1);
        assertEq(mockLedger.lastEventId(), EVENT_ID);
    }

    // ---------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------
    function _settlement(bytes32 accountId, int128 amount)
        internal
        pure
        returns (EventTypes.Settlement memory)
    {
        EventTypes.SettlementExecution[] memory se = new EventTypes.SettlementExecution[](1);
        se[0] = EventTypes.SettlementExecution({
            symbolHash: SYMBOL,
            markPrice: 1,
            sumUnitaryFundings: 0,
            settledAmount: amount
        });
        return EventTypes.Settlement({
            accountId: accountId,
            settledAssetHash: ASSET,
            insuranceAccountId: INSURANCE,
            settledAmount: amount,
            insuranceTransferAmount: 0,
            timestamp: 1,
            settlementExecutions: se
        });
    }

    /// blob = X ++ evilBody ++ signedBody, X == 32 + evilBody.length
    function _forgeBlob(EventTypes.Settlement memory signedSettlement, EventTypes.Settlement memory evilSettlement)
        internal
        pure
        returns (bytes memory)
    {
        bytes memory evilBody = _tail(abi.encode(evilSettlement), 32);
        bytes memory signedBody = _tail(abi.encode(signedSettlement), 32);
        return bytes.concat(abi.encode(uint256(32 + evilBody.length)), evilBody, signedBody);
    }

    function _forgedUpload() internal view returns (EventTypes.EventUpload memory) {
        EventTypes.EventUploadData[] memory events = new EventTypes.EventUploadData[](1);
        events[0] = EventTypes.EventUploadData({
            bizType: uint8(Signature.BizType.Settlement),
            eventId: EVENT_ID,
            data: _forgeBlob(_settlement(SIGNED_ACCOUNT, 1), _settlement(ATTACKER_ACCOUNT, 1_000_000e6))
        });
        return _sign(EventTypes.EventUpload({batchId: om.eventUploadBatchId(), count: 1, events: events, r: 0, s: 0, v: 0}));
    }

    /// reproduces Signature.eventsUploadEncodeHash for a single settlement event
    function _digest(EventTypes.EventUpload memory data) internal pure returns (bytes32) {
        Signature.EventUploadSignature memory sig = Signature.EventUploadSignature({
            batchId: data.batchId,
            withdraws: new Signature.WithdrawDataSignature[](0),
            settlements: new Signature.SettlementSignature[](1),
            adls: new Signature.AdlSignature[](0),
            liquidations: new Signature.LiquidationSignature[](0),
            feeDistributions: new Signature.FeeDistributionSignature[](0),
            delegateSigners: new Signature.DelegeteSignerSignature[](0),
            adlV2s: new Signature.AdlV2Signature[](0),
            liquidationV2s: new Signature.LiquidationV2Signature[](0),
            withdrawSols: new Signature.WithdrawSolDataSignature[](0),
            withdraw2Contracts: new Signature.Withdraw2ContractSignature[](0),
            balanceTransfers: new Signature.BalanceTransferSignature[](0),
            swapUploads: new Signature.SwapUploadSignature[](0),
            withdraw2ContractV2s: new Signature.Withdraw2ContractV2Signature[](0),
            isoSettlements: new Signature.SettlementV3Signature[](0),
            isoAdls: new Signature.AdlV3Signature[](0),
            isoLiquidations: new Signature.LiquidationV3Signature[](0),
            isoMarginTransfers: new Signature.MarginTransferV3Signature[](0)
        });

        EventTypes.Settlement memory s = abi.decode(data.events[0].data, (EventTypes.Settlement));
        sig.settlements[0] = Signature.SettlementSignature({
            eventId: data.events[0].eventId,
            accountId: s.accountId,
            settledAmount: s.settledAmount,
            settledAssetHash: s.settledAssetHash,
            insuranceAccountId: s.insuranceAccountId,
            insuranceTransferAmount: s.insuranceTransferAmount,
            settlementExecutions: s.settlementExecutions,
            timestamp: s.timestamp
        });

        return keccak256(
            abi.encode(sig.batchId, sig.withdraws, sig.settlements, sig.adls, sig.liquidations)
        );
    }

    function _verify(EventTypes.EventUpload memory data) internal view returns (bool) {
        return ECDSA.recover(ECDSA.toEthSignedMessageHash(_digest(data)), data.v, data.r, data.s) == engine;
    }

    function _sign(EventTypes.EventUpload memory data) internal view returns (EventTypes.EventUpload memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ENGINE_PK, ECDSA.toEthSignedMessageHash(_digest(data)));
        data.v = v;
        data.r = r;
        data.s = s;
        return data;
    }

    function _tail(bytes memory b, uint256 from) internal pure returns (bytes memory out) {
        out = new bytes(b.length - from);
        for (uint256 i = 0; i < out.length; ++i) {
            out[i] = b[from + i];
        }
    }
}
