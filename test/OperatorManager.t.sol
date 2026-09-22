// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import "../src/OperatorManager.sol";
import "../src/Ledger.sol";
import "../src/VaultManager.sol";
import "./mock/LedgerCrossChainManagerMock.sol";

contract OperatorManagerTest is Test {
    ProxyAdmin admin;
    address constant operatorAddress = address(0x1234567890);
    ILedgerCrossChainManager ledgerCrossChainManager;
    OperatorManager operatorManager;
    IVaultManager vaultManager;
    ILedger ledger;
    TransparentUpgradeableProxy operatorProxy;
    TransparentUpgradeableProxy vaultProxy;
    TransparentUpgradeableProxy ledgerProxy;

    function setUp() public {
        admin = new ProxyAdmin();

        ledgerCrossChainManager = new LedgerCrossChainManagerMock();
        IOperatorManager operatorManagerImpl = new OperatorManager();
        IVaultManager vaultManagerImpl = new VaultManager();
        ILedger ledgerImpl = new Ledger();

        operatorProxy = new TransparentUpgradeableProxy(address(operatorManagerImpl), address(admin), "");
        vaultProxy = new TransparentUpgradeableProxy(address(vaultManagerImpl), address(admin), "");
        ledgerProxy = new TransparentUpgradeableProxy(address(ledgerImpl), address(admin), "");

        operatorManager = OperatorManager(address(operatorProxy));
        vaultManager = IVaultManager(address(vaultProxy));
        ledger = ILedger(address(ledgerProxy));

        operatorManager.initialize();
        vaultManager.initialize();
        ledger.initialize();

        ledger.setOperatorManagerAddress(address(operatorManager));
        ledger.setCrossChainManager(address(ledgerCrossChainManager));
        ledger.setVaultManager(address(vaultManager));

        operatorManager.setOperator(operatorAddress);
        operatorManager.setLedger(address(ledger));

        ledgerCrossChainManager.setLedger(address(ledger));
        ledgerCrossChainManager.setOperatorManager(address(operatorManager));

        vaultManager.setLedgerAddress(address(ledger));
    }

    function test_ping() public {
        vm.prank(operatorAddress);
        operatorManager.operatorPing();
    }

    function testRevert_pingNotOperator() public {
        vm.prank(address(0x1));
        vm.expectRevert(IError.OnlyOperatorCanCall.selector);
        operatorManager.operatorPing();
    }

    function test_engineNotDown() public {
        bool isDown = operatorManager.checkEngineDown();
        assertEq(isDown, false);
    }

    // function selectors on Ledger contract: https://testnet-explorer.orderly.org/address/0x8794E7260517B1766fc7b55cAfcd56e6bf08600e?tab=write_proxy
    function test_biztype_selector() public {
        operatorManager.initBizTypeToSelector();
        assertTrue(operatorManager.bizTypeToSelectors(1) == 0x965a1cba);    // executeWithdrawAction
        assertTrue(operatorManager.bizTypeToSelectors(2) == 0x7c6c3bd5);    // executeSettlement
        assertTrue(operatorManager.bizTypeToSelectors(3) == 0xc61ca104);    // executeAdl   
        assertTrue(operatorManager.bizTypeToSelectors(4) == 0x619fa7fe);    // executeLiquidation   
        assertTrue(operatorManager.bizTypeToSelectors(5) == 0x9078ffd8);    // executeFeeDistribution
        assertTrue(operatorManager.bizTypeToSelectors(6) == 0x0997c228);    // executeDelegateSigner
        assertTrue(operatorManager.bizTypeToSelectors(7) == 0xec0a14aa);    // executeDelegateWithdrawAction
        assertTrue(operatorManager.bizTypeToSelectors(8) == 0xf97a259c);    // executeAdlV2
        assertTrue(operatorManager.bizTypeToSelectors(9) == 0xb8375d1f);    // executeLiquidationV2
        assertTrue(operatorManager.bizTypeToSelectors(10) == 0xd2050cb5);   // executeWithdrawSolAction
        assertTrue(operatorManager.bizTypeToSelectors(11) == 0xa71e351f);   // executeWithdraw2Contract
        assertTrue(operatorManager.bizTypeToSelectors(12) == 0xf83bd887);   // executeBalanceTransfer
        assertTrue(operatorManager.bizTypeToSelectors(13) == 0xae5f766e);   // executeSwapResultUpload
        assertTrue(operatorManager.bizTypeToSelectors(14) == 0x9df6d026);   // executeWithdraw2ContractV2

    }

    // ---------- setAllowedSymbol tests ----------
    using ECDSA for bytes32;

    bytes32 constant SYMBOL_MANAGER_ROLE = keccak256("ORDERLY_MANAGER_SYMBOL_MANAGER_ROLE");
    uint256 constant CEFI_PRIVATE_KEY =
        0x4f3edf983ac636a65a842ce7c78d9aa706d3b113bce036f9d6f235a491091696;

    /// @notice Success path: operator calls setAllowedSymbol with valid CEFI signature; passes verification and updates VaultManager.
    function test_setAllowedSymbol_success() public {
        vm.chainId(291);

        operatorManager.setVaultManager(address(vaultManager));
        // Set permissionlessListingSignerAddress
        address cefiSigner = vm.addr(CEFI_PRIVATE_KEY);
        operatorManager.setPermissionlessListingSignerAddress(cefiSigner);

        // VaultManager.setAllowedSymbolByOperator requires SYMBOL_MANAGER_ROLE; owner grants it to OperatorManager
        VaultManager(address(vaultManager)).grantRole(SYMBOL_MANAGER_ROLE, address(operatorManager));

        // Business params
        bytes32 symbolHash = 0xe3ed72b93c91c8c78347689fd6f9b0d13a00f484b9d3cdc8413bcf4a53c90e89;
        bool allowed = true;
        uint64 sequenceId = 123456;

        // Set permissionlessListingSequenceId to 123455 (expected next value is +1).
        bytes32 signerAndSeqSlot = vm.load(address(operatorManager), bytes32(uint256(0x70)));
        
        // << 160 places the 64 bits after the 160-bit (address) field; mask clears that 64-bit slot then we set it to 123455
        uint256 cleared = uint256(signerAndSeqSlot) & ~(uint256(type(uint64).max) << 160);
        vm.store(
            address(operatorManager),
            bytes32(uint256(0x70)),
            bytes32(cleared | (uint256(123455) << 160))
        );
        assertEq(operatorManager.permissionlessListingSequenceId(), 123455, "sequenceId should be preset");

        bytes memory cefiSignature;
        {
            bytes32 messageHash = keccak256(abi.encode(symbolHash, allowed, sequenceId, block.chainid));
            bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(CEFI_PRIVATE_KEY, ethSignedHash);
            cefiSignature = abi.encodePacked(r, s, v);
        }

        vm.prank(operatorAddress);
        operatorManager.setAllowedSymbol(symbolHash, allowed, sequenceId, block.chainid, cefiSignature);

        assertTrue(vaultManager.getAllowedSymbol(symbolHash), "symbol should be allowed");
        assertEq(operatorManager.permissionlessListingSequenceId(), sequenceId, "sequenceId should be updated");
    }

    /// @notice Call should revert with VaultManagerNotSet when VaultManager is not set.
    function test_setAllowedSymbol_revertWhenVaultManagerNotSet() public {
        address cefiSigner = vm.addr(CEFI_PRIVATE_KEY);
        operatorManager.setPermissionlessListingSignerAddress(cefiSigner);
        bytes32 symbolHash = keccak256(bytes("PERP_BTC_USDC"));
        bytes memory cefiSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.prank(operatorAddress);
        vm.expectRevert(IError.VaultManagerNotSet.selector);
        operatorManager.setAllowedSymbol(symbolHash, true, 1, block.chainid, cefiSignature);
    }

    /// @notice Call should revert with PermissionlessListingSignerNotSet when CEFI signer address is not set.
    function test_setAllowedSymbol_revertWhenPermissionlessListingSignerNotSet() public {
        operatorManager.setVaultManager(address(vaultManager));
        bytes32 symbolHash = keccak256(bytes("PERP_BTC_USDC"));
        bytes memory cefiSignature = abi.encodePacked(bytes32(0), bytes32(0), uint8(0));

        vm.prank(operatorAddress);
        vm.expectRevert(IError.PermissionlessListingSignerNotSet.selector);
        operatorManager.setAllowedSymbol(symbolHash, true, 1, block.chainid, cefiSignature);
    }

    /// @notice Call should revert with InvalidSequenceId when sequenceId != permissionlessListingSequenceId + 1.
    function test_setAllowedSymbol_revertWhenInvalidSequenceId() public {
        operatorManager.setVaultManager(address(vaultManager));
        address cefiSigner = vm.addr(CEFI_PRIVATE_KEY);
        operatorManager.setPermissionlessListingSignerAddress(cefiSigner);
        VaultManager(address(vaultManager)).grantRole(SYMBOL_MANAGER_ROLE, address(operatorManager));

        bytes32 symbolHash = keccak256(bytes("PERP_BTC_USDC"));
        uint64 wrongSequenceId = 2; // Current is 0, expected is 1

        bytes32 messageHash = keccak256(abi.encode(symbolHash, true, wrongSequenceId, block.chainid));
        bytes32 ethSignedHash = messageHash.toEthSignedMessageHash();
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(CEFI_PRIVATE_KEY, ethSignedHash);
        bytes memory cefiSignature = abi.encodePacked(r, s, v);

        // Operator calls setAllowedSymbol
        vm.prank(operatorAddress);
        vm.expectRevert(
            abi.encodeWithSelector(IError.InvalidSequenceId.selector, uint256(wrongSequenceId), uint256(1))
        );
        operatorManager.setAllowedSymbol(symbolHash, true, wrongSequenceId, block.chainid, cefiSignature);
    }

}
