#!/usr/bin/env bash
#
# Verify a CREATE2-deployed impl contract on block explorer.
#
# Usage:
#   ./script/v3/verify.sh <ContractName> <DeployedAddress> <Network>
#
# Examples:
#   ./script/v3/verify.sh LedgerImplA 0xf4D944B9...dCc3 orderly-testnet
#   ./script/v3/verify.sh Vault 0x1234...5678 arbitrum
#   ./script/v3/verify.sh LedgerImplB 0xabcd...ef01 orderly
#
# Env vars required for Etherscan networks:
#   See .env for chain-specific API keys (ETHERSCAN_API_KEY, etc.)

set -euo pipefail

# Load .env if present
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# ==================== Input ====================

if [ $# -lt 3 ]; then
    echo "Usage: $0 <ContractName> <DeployedAddress> <Network>"
    echo ""
    echo "Supported contract names:"
    echo "  LedgerImplA, LedgerImplB, LedgerImplC, LedgerImplD, LedgerImplView"
    echo "  OperatorManagerImplA, OperatorManagerImplB"
    echo "  Ledger, OperatorManager, VaultManager, MarketManager, FeeManager"
    echo "  Vault, OperatorManagerZip"
    echo ""
    echo "Supported networks (mainnet):"
    echo "  Blockscout: orderly, story, morph, plume, mode"
    echo "  Etherscan:  arbitrum, optimism, polygon, base, ethereum, mantle, berachain, bsc, sei,"
    echo "              abstract, monad, avalanche, sonic"
    echo ""
    echo "Supported networks (testnet):"
    echo "  Blockscout: orderly-testnet, story-testnet, morph-testnet"
    echo "  Etherscan:  arbitrum-testnet, optimism-testnet, polygon-testnet, base-testnet,"
    echo "              ethereum-testnet, mantle-testnet, sei-testnet, abstract-testnet,"
    echo "              bsc-testnet, monad-testnet, plume-testnet, avalanche-testnet, sonic-testnet"
    echo "  Routescan:  mode-testnet"
    exit 1
fi

CONTRACT_NAME="$1"
ADDRESS="$2"
NETWORK="$3"

# ==================== Contract path mapping ====================

get_contract_path() {
    case "$1" in
        LedgerImplA)          echo "src/LedgerImplA.sol:LedgerImplA" ;;
        LedgerImplB)          echo "src/LedgerImplB.sol:LedgerImplB" ;;
        LedgerImplC)          echo "src/LedgerImplC.sol:LedgerImplC" ;;
        LedgerImplD)          echo "src/LedgerImplD.sol:LedgerImplD" ;;
        LedgerImplView)       echo "src/LedgerImplView.sol:LedgerImplView" ;;
        OperatorManagerImplA) echo "src/OperatorManagerImplA.sol:OperatorManagerImplA" ;;
        OperatorManagerImplB) echo "src/OperatorManagerImplB.sol:OperatorManagerImplB" ;;
        Ledger)               echo "src/Ledger.sol:Ledger" ;;
        OperatorManager)      echo "src/OperatorManager.sol:OperatorManager" ;;
        VaultManager)         echo "src/VaultManager.sol:VaultManager" ;;
        MarketManager)        echo "src/MarketManager.sol:MarketManager" ;;
        FeeManager)           echo "src/FeeManager.sol:FeeManager" ;;
        Vault)                echo "src/vaultSide/Vault.sol:Vault" ;;
        OperatorManagerZip)   echo "src/zip/OperatorManagerZip.sol:OperatorManagerZip" ;;
        *)
            echo "Unknown contract: $1" >&2
            exit 1
            ;;
    esac
}

# ==================== Network config ====================
# Returns: VERIFIER_TYPE CHAIN_ID_OR_URL RPC_ENV [API_KEY_ENV]
#
# For blockscout/routescan: CHAIN_ID_OR_URL is the verifier URL
# For etherscan: CHAIN_ID_OR_URL is the chain ID (forge handles the API URL)

get_network_config() {
    case "$1" in
        # --- Blockscout (mainnet) ---
        orderly)
            echo "blockscout https://explorer.orderly.network/api? RPC_URL_ORDERLY" ;;
        story)
            echo "blockscout https://storyscan.xyz/api? RPC_URL_STORY" ;;
        morph)
            echo "blockscout https://explorer.morphl2.io/api? RPC_URL_MORPH" ;;
        plume)
            echo "blockscout https://phoenix-explorer.plumenetwork.xyz/api? RPC_URL_PLUME" ;;
        mode)
            echo "blockscout https://explorer.mode.network/api? RPC_URL_MODE" ;;

        # --- Blockscout (testnet) ---
        orderly-testnet)
            echo "blockscout https://testnet-explorer.orderly.org/api? RPC_URL_ORDERLY_TESTNET" ;;
        story-testnet)
            echo "blockscout https://testnet.storyscan.xyz/api? RPC_URL_STORY_TESTNET" ;;
        morph-testnet)
            echo "blockscout https://explorer-api-holesky.morphl2.io/api? RPC_URL_MORPH_TESTNET" ;;

        # --- Etherscan (mainnet) --- uses --chain <chainid>, forge resolves API URL
        arbitrum)
            echo "etherscan 42161 RPC_URL_ARBITRUM ETHERSCAN_API_KEY" ;;
        optimism)
            echo "etherscan 10 RPC_URL_OPTIMISM ETHERSCAN_API_KEY" ;;
        polygon)
            echo "etherscan 137 RPC_URL_POLYGON ETHERSCAN_API_KEY" ;;
        base)
            echo "etherscan 8453 RPC_URL_BASE ETHERSCAN_API_KEY" ;;
        ethereum)
            echo "etherscan 1 RPC_URL_ETHEREUM ETHERSCAN_API_KEY" ;;
        mantle)
            echo "etherscan 5000 RPC_URL_MANTLE ETHERSCAN_API_KEY" ;;
        berachain)
            echo "etherscan 80094 RPC_URL_BERACHAIN ETHERSCAN_API_KEY" ;;
        bsc)
            echo "etherscan 56 RPC_URL_BSC ETHERSCAN_API_KEY" ;;
        sei)
            echo "etherscan 1329 RPC_URL_SEI ETHERSCAN_API_KEY" ;;
        abstract)
            echo "etherscan 2741 RPC_URL_ABSTRACT ETHERSCAN_API_KEY" ;;
        monad)
            echo "etherscan 143 RPC_URL_MONAD ETHERSCAN_API_KEY" ;;
        avalanche)
            echo "etherscan 43114 RPC_URL_AVALANCHE ETHERSCAN_API_KEY" ;;
        sonic)
            echo "etherscan 146 RPC_URL_SONIC ETHERSCAN_API_KEY" ;;

        # --- Etherscan (testnet) ---
        arbitrum-testnet)
            echo "etherscan 421614 RPC_URL_ARBITRUM_TESTNET ETHERSCAN_API_KEY" ;;
        optimism-testnet)
            echo "etherscan 11155420 RPC_URL_OPTIMISM_TESTNET ETHERSCAN_API_KEY" ;;
        polygon-testnet)
            echo "etherscan 80002 RPC_URL_POLYGON_TESTNET ETHERSCAN_API_KEY" ;;
        base-testnet)
            echo "etherscan 84532 RPC_URL_BASE_TESTNET ETHERSCAN_API_KEY" ;;
        ethereum-testnet)
            echo "etherscan 11155111 RPC_URL_ETHEREUM_TESTNET ETHERSCAN_API_KEY" ;;
        mantle-testnet)
            echo "etherscan 5003 RPC_URL_MANTLE_TESTNET ETHERSCAN_API_KEY" ;;
        abstract-testnet)
            echo "etherscan 11124 RPC_URL_ABSTRACT_TESTNET ETHERSCAN_API_KEY" ;;
        bsc-testnet)
            echo "etherscan 97 RPC_URL_BSC_TESTNET ETHERSCAN_API_KEY" ;;
        monad-testnet)
            echo "etherscan 10143 RPC_URL_MONAD_TESTNET ETHERSCAN_API_KEY" ;;
        plume-testnet)
            echo "etherscan 98867 RPC_URL_PLUME_TESTNET ETHERSCAN_API_KEY" ;;
        sei-testnet)
            echo "etherscan 713715 RPC_URL_SEI_TESTNET ETHERSCAN_API_KEY" ;;
        avalanche-testnet)
            echo "etherscan 43113 RPC_URL_AVALANCHE_TESTNET ETHERSCAN_API_KEY" ;;
        sonic-testnet)
            echo "etherscan 57054 RPC_URL_SONIC_TESTNET ETHERSCAN_API_KEY" ;;

        # --- Routescan (testnet, no networks.json entry) ---
        mode-testnet)
            echo "routescan https://api.routescan.io/v2/network/testnet/evm/34443/etherscan RPC_URL_MODE_TESTNET" ;;
        *)
            echo "Unknown network: $1" >&2
            exit 1
            ;;
    esac
}

# ==================== Main ====================

CONTRACT_PATH=$(get_contract_path "$CONTRACT_NAME")
read -r VERIFIER_TYPE CHAIN_ID_OR_URL RPC_ENV API_KEY_ENV <<< "$(get_network_config "$NETWORK")"

RPC_URL="${!RPC_ENV:?Environment variable $RPC_ENV is not set}"

echo "=== Verify Contract ==="
echo "Contract:  $CONTRACT_NAME ($CONTRACT_PATH)"
echo "Address:   $ADDRESS"
echo "Network:   $NETWORK"
echo "Verifier:  $VERIFIER_TYPE"
echo ""

case "$VERIFIER_TYPE" in
    blockscout)
        forge verify-contract \
            "$ADDRESS" "$CONTRACT_PATH" \
            --rpc-url "$RPC_URL" \
            --verifier blockscout \
            --verifier-url "$CHAIN_ID_OR_URL" \
            --compiler-version "0.8.26" \
            --num-of-optimizations 1000 \
            --watch
        ;;
    etherscan)
        API_KEY="${!API_KEY_ENV:?Environment variable $API_KEY_ENV is not set}"
        forge verify-contract \
            "$ADDRESS" "$CONTRACT_PATH" \
            --rpc-url "$RPC_URL" \
            --chain "$CHAIN_ID_OR_URL" \
            --etherscan-api-key "$API_KEY" \
            --compiler-version "0.8.26" \
            --num-of-optimizations 1000 \
            --watch
        ;;
    routescan)
        forge verify-contract \
            "$ADDRESS" "$CONTRACT_PATH" \
            --rpc-url "$RPC_URL" \
            --verifier-url "$CHAIN_ID_OR_URL" \
            --etherscan-api-key "verifyContract" \
            --compiler-version "0.8.26" \
            --num-of-optimizations 1000 \
            --watch
        ;;
esac

echo ""
echo "Verification submitted for $CONTRACT_NAME at $ADDRESS on $NETWORK"
