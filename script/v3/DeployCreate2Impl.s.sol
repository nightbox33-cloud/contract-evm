// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.18;

import "forge-std/Script.sol";
import "../utils/BaseScript.s.sol";
import "../utils/ConfigHelper.s.sol";

// Delegatecall impl contracts
import "../../src/LedgerImplA.sol";
import "../../src/LedgerImplB.sol";
import "../../src/LedgerImplC.sol";
import "../../src/LedgerImplD.sol";
import "../../src/LedgerImplView.sol";
import "../../src/OperatorManagerImplA.sol";
import "../../src/OperatorManagerImplB.sol";

// Proxy impl contracts
import "../../src/Ledger.sol";
import "../../src/OperatorManager.sol";
import "../../src/VaultManager.sol";
import "../../src/MarketManager.sol";
import "../../src/FeeManager.sol";
import "../../src/vaultSide/Vault.sol";
import "../../src/zip/OperatorManagerZip.sol";

/// @title DeployCreate2Impl
/// @notice Unified CREATE2 deployment script for all impl contracts.
/// @dev Usage:
///   Single:    forge script script/v3/DeployCreate2Impl.s.sol --sig "run(string)" "LedgerImplA" --rpc-url <url> --broadcast
///   Batch:     forge script script/v3/DeployCreate2Impl.s.sol --sig "runAll()" --rpc-url <url> --broadcast
///   Predict:   forge script script/v3/DeployCreate2Impl.s.sol --sig "predict(string)" "LedgerImplA" --rpc-url <url>
///   PredictAll: forge script script/v3/DeployCreate2Impl.s.sol --sig "predictAll()" --rpc-url <url>
///
///   Env vars:
///     ORDERLY_PRIVATE_KEY  - deployer private key (required)
///     DEPLOY_SALT          - bytes32 salt for CREATE2 (optional, default: bytes32(0))
contract DeployCreate2Impl is BaseScript, ConfigHelper {
    // --- Name hash constants for O(1) dispatch ---
    bytes32 private constant HASH_LEDGER_IMPL_A = keccak256("LedgerImplA");
    bytes32 private constant HASH_LEDGER_IMPL_B = keccak256("LedgerImplB");
    bytes32 private constant HASH_LEDGER_IMPL_C = keccak256("LedgerImplC");
    bytes32 private constant HASH_LEDGER_IMPL_D = keccak256("LedgerImplD");
    bytes32 private constant HASH_LEDGER_IMPL_VIEW = keccak256("LedgerImplView");
    bytes32 private constant HASH_OPERATOR_MANAGER_IMPL_A = keccak256("OperatorManagerImplA");
    bytes32 private constant HASH_OPERATOR_MANAGER_IMPL_B = keccak256("OperatorManagerImplB");
    bytes32 private constant HASH_LEDGER = keccak256("Ledger");
    bytes32 private constant HASH_OPERATOR_MANAGER = keccak256("OperatorManager");
    bytes32 private constant HASH_VAULT_MANAGER = keccak256("VaultManager");
    bytes32 private constant HASH_MARKET_MANAGER = keccak256("MarketManager");
    bytes32 private constant HASH_FEE_MANAGER = keccak256("FeeManager");
    bytes32 private constant HASH_VAULT = keccak256("Vault");
    bytes32 private constant HASH_OPERATOR_MANAGER_ZIP = keccak256("OperatorManagerZip");

    // All contract names for batch iteration
    string[14] private CONTRACT_NAMES = [
        "LedgerImplA",
        "LedgerImplB",
        "LedgerImplC",
        "LedgerImplD",
        "LedgerImplView",
        "OperatorManagerImplA",
        "OperatorManagerImplB",
        "Ledger",
        "OperatorManager",
        "VaultManager",
        "MarketManager",
        "FeeManager",
        "Vault",
        "OperatorManagerZip"
    ];

    // ==================== Entry Points ====================

    /// @notice Deploy a single contract by name using CREATE2.
    function run(string calldata contractName) external {
        uint256 deployerPk = vm.envUint("ORDERLY_PRIVATE_KEY");
        bytes32 salt = _getSalt();

        address predicted = _predictAddress(contractName, salt);
        console.log("=== CREATE2 Deploy ===");
        console.log("Contract:          ", contractName);
        console.log("Salt:              ");
        console.logBytes32(salt);
        console.log("Predicted address: ", predicted);

        if (_isDeployed(predicted)) {
            console.log("SKIP: already deployed at predicted address");
            return;
        }

        vm.startBroadcast(deployerPk);
        address deployed = _deploy(contractName, salt);
        vm.stopBroadcast();

        require(deployed == predicted, "CREATE2 address mismatch");
        console.log("Deployed address:  ", deployed);
        console.log("Done!");
    }

    /// @notice Deploy all 14 contracts in one broadcast session.
    function runAll() external {
        uint256 deployerPk = vm.envUint("ORDERLY_PRIVATE_KEY");
        bytes32 salt = _getSalt();

        console.log("=== CREATE2 Batch Deploy ===");
        console.log("Salt:");
        console.logBytes32(salt);
        console.log("");

        vm.startBroadcast(deployerPk);
        for (uint256 i = 0; i < CONTRACT_NAMES.length; i++) {
            string memory name = CONTRACT_NAMES[i];
            address predicted = _predictAddress(name, salt);

            if (_isDeployed(predicted)) {
                console.log("SKIP (exists):", name, predicted);
                continue;
            }

            address deployed = _deploy(name, salt);
            require(deployed == predicted, "CREATE2 address mismatch");
            console.log("Deployed:", name, deployed);
        }
        vm.stopBroadcast();

        console.log("");
        console.log("Batch deploy done!");
    }

    /// @notice Predict a single contract's CREATE2 address (read-only, no broadcast).
    function predict(string calldata contractName) external view {
        bytes32 salt = _getSalt();
        address predicted = _predictAddress(contractName, salt);

        console.log("=== CREATE2 Predict ===");
        console.log("Contract:", contractName);
        console.log("Factory: ", CREATE2_FACTORY);
        console.log("Salt:");
        console.logBytes32(salt);
        console.log("Address: ", predicted);
    }

    /// @notice Predict all 14 contract addresses (read-only, no broadcast).
    function predictAll() external view {
        bytes32 salt = _getSalt();

        console.log("=== CREATE2 Predict All ===");
        console.log("Factory:", CREATE2_FACTORY);
        console.log("Salt:");
        console.logBytes32(salt);
        console.log("");

        for (uint256 i = 0; i < CONTRACT_NAMES.length; i++) {
            string memory name = CONTRACT_NAMES[i];
            address predicted = _predictAddress(name, salt);
            console.log(name, "=>", predicted);
        }
    }

    // ==================== Internal Helpers ====================

    /// @dev Load salt from DEPLOY_SALT env var as a string, then keccak256 hash it.
    ///      e.g. DEPLOY_SALT="orderly-v3-round1" => keccak256("orderly-v3-round1")
    ///      If not set, defaults to bytes32(0).
    function _getSalt() internal view returns (bytes32) {
        try vm.envString("DEPLOY_SALT") returns (string memory saltStr) {
            return keccak256(bytes(saltStr));
        } catch {
            return bytes32(0);
        }
    }

    /// @dev Check if a contract is already deployed at the given address.
    function _isDeployed(address addr) internal view returns (bool) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(addr)
        }
        return codeSize > 0;
    }

    /// @dev Predict the CREATE2 address for a given contract name.
    ///      Foundry routes `new{salt}()` through the deterministic CREATE2 factory
    ///      at 0x4e59b44847b379578588920cA78FbF26c0B4956C during broadcast.
    function _predictAddress(string memory name, bytes32 salt) internal pure returns (address) {
        bytes32 initCodeHash = _getInitCodeHash(name);
        return computeCreate2Address(salt, initCodeHash);
    }

    /// @dev Get keccak256(creationCode) for a given contract name.
    function _getInitCodeHash(string memory name) internal pure returns (bytes32) {
        bytes32 nameHash = keccak256(bytes(name));

        if (nameHash == HASH_LEDGER_IMPL_A) return hashInitCode(type(LedgerImplA).creationCode);
        if (nameHash == HASH_LEDGER_IMPL_B) return hashInitCode(type(LedgerImplB).creationCode);
        if (nameHash == HASH_LEDGER_IMPL_C) return hashInitCode(type(LedgerImplC).creationCode);
        if (nameHash == HASH_LEDGER_IMPL_D) return hashInitCode(type(LedgerImplD).creationCode);
        if (nameHash == HASH_LEDGER_IMPL_VIEW) return hashInitCode(type(LedgerImplView).creationCode);
        if (nameHash == HASH_OPERATOR_MANAGER_IMPL_A) return hashInitCode(type(OperatorManagerImplA).creationCode);
        if (nameHash == HASH_OPERATOR_MANAGER_IMPL_B) return hashInitCode(type(OperatorManagerImplB).creationCode);
        if (nameHash == HASH_LEDGER) return hashInitCode(type(Ledger).creationCode);
        if (nameHash == HASH_OPERATOR_MANAGER) return hashInitCode(type(OperatorManager).creationCode);
        if (nameHash == HASH_VAULT_MANAGER) return hashInitCode(type(VaultManager).creationCode);
        if (nameHash == HASH_MARKET_MANAGER) return hashInitCode(type(MarketManager).creationCode);
        if (nameHash == HASH_FEE_MANAGER) return hashInitCode(type(FeeManager).creationCode);
        if (nameHash == HASH_VAULT) return hashInitCode(type(Vault).creationCode);
        if (nameHash == HASH_OPERATOR_MANAGER_ZIP) return hashInitCode(type(OperatorManagerZip).creationCode);

        revert(string.concat("Unknown contract: ", name));
    }

    /// @dev Deploy a contract by name using CREATE2 with the given salt.
    function _deploy(string memory name, bytes32 salt) internal returns (address) {
        bytes32 nameHash = keccak256(bytes(name));

        if (nameHash == HASH_LEDGER_IMPL_A) return address(new LedgerImplA{salt: salt}());
        if (nameHash == HASH_LEDGER_IMPL_B) return address(new LedgerImplB{salt: salt}());
        if (nameHash == HASH_LEDGER_IMPL_C) return address(new LedgerImplC{salt: salt}());
        if (nameHash == HASH_LEDGER_IMPL_D) return address(new LedgerImplD{salt: salt}());
        if (nameHash == HASH_LEDGER_IMPL_VIEW) return address(new LedgerImplView{salt: salt}());
        if (nameHash == HASH_OPERATOR_MANAGER_IMPL_A) return address(new OperatorManagerImplA{salt: salt}());
        if (nameHash == HASH_OPERATOR_MANAGER_IMPL_B) return address(new OperatorManagerImplB{salt: salt}());
        if (nameHash == HASH_LEDGER) return address(new Ledger{salt: salt}());
        if (nameHash == HASH_OPERATOR_MANAGER) return address(new OperatorManager{salt: salt}());
        if (nameHash == HASH_VAULT_MANAGER) return address(new VaultManager{salt: salt}());
        if (nameHash == HASH_MARKET_MANAGER) return address(new MarketManager{salt: salt}());
        if (nameHash == HASH_FEE_MANAGER) return address(new FeeManager{salt: salt}());
        if (nameHash == HASH_VAULT) return address(new Vault{salt: salt}());
        if (nameHash == HASH_OPERATOR_MANAGER_ZIP) return address(new OperatorManagerZip{salt: salt}());

        revert(string.concat("Unknown contract: ", name));
    }
}
