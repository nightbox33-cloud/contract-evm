# V3 CREATE2 Deployment Script

Unified deployment script for all impl contracts using CREATE2 deterministic addresses.

## Prerequisites

- `ORDERLY_PRIVATE_KEY` env var set (deployer private key)
- `DEPLOY_SALT` env var (optional, string, hashed via `keccak256`, default: `bytes32(0)`)
- RPC URL configured in `.env` or `foundry.toml` `[rpc_endpoints]`

## Commands

### Deploy Single Contract

```bash
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "run(string)" "<ContractName>" \
    --rpc-url <network> --broadcast
```

Examples:

```bash
# Deploy LedgerImplA to orderly testnet
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "run(string)" "LedgerImplA" \
    --rpc-url orderly-testnet --broadcast

# Deploy Vault to arbitrum
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "run(string)" "Vault" \
    --rpc-url arbitrum --broadcast

# Deploy with custom salt
DEPLOY_SALT="orderly-v3-round2" \
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "run(string)" "LedgerImplA" \
    --rpc-url orderly --broadcast
```

### Deploy All 14 Contracts (Batch)

```bash
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "runAll()" \
    --rpc-url <network> --broadcast
```

Already-deployed contracts (same salt + same bytecode) are automatically skipped.

### Predict Single Address (No Deploy)

```bash
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "predict(string)" "<ContractName>" \
    --rpc-url <network>
```

### Predict All 14 Addresses (No Deploy)

```bash
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "predictAll()" \
    --rpc-url <network>
```

## Supported Contracts

| Name | Source |
|------|--------|
| `LedgerImplA` | `src/LedgerImplA.sol` |
| `LedgerImplB` | `src/LedgerImplB.sol` |
| `LedgerImplC` | `src/LedgerImplC.sol` |
| `LedgerImplD` | `src/LedgerImplD.sol` |
| `LedgerImplView` | `src/LedgerImplView.sol` |
| `OperatorManagerImplA` | `src/OperatorManagerImplA.sol` |
| `OperatorManagerImplB` | `src/OperatorManagerImplB.sol` |
| `Ledger` | `src/Ledger.sol` |
| `OperatorManager` | `src/OperatorManager.sol` |
| `VaultManager` | `src/VaultManager.sol` |
| `MarketManager` | `src/MarketManager.sol` |
| `FeeManager` | `src/FeeManager.sol` |
| `Vault` | `src/vaultSide/Vault.sol` |
| `OperatorManagerZip` | `src/zip/OperatorManagerZip.sol` |

## Available RPC Network Names

Configured in `foundry.toml` under `[rpc_endpoints]`. Naming convention: `NetworkName` (mainnet), `NetworkName-testnet` (testnet).

**Orderly Settlement Chain:**
`orderly`, `orderly-testnet`

**Mainnet:**
`arbitrum`, `base`, `optimism`, `polygon`, `mantle`, `avalanche`, `sei`, `sonic`, `berachain`, `morph`, `story`, `mode`, `plume`, `bsc`, `ethereum`

**Testnet:**
`arbitrum-testnet`, `base-testnet`, `optimism-testnet`, `polygon-testnet`, `mantle-testnet`, `avalanche-testnet`, `sei-testnet`, `sonic-testnet`, `berachain-testnet`, `morph-testnet`, `story-testnet`, `mode-testnet`, `plume-testnet`, `bsc-testnet`, `ethereum-testnet`

## Salt Management

- `DEPLOY_SALT` is a plain string in `.env`, the script hashes it via `keccak256`
  ```bash
  DEPLOY_SALT="orderly-v3-round1"    # => keccak256("orderly-v3-round1")
  ```
- If not set, defaults to `bytes32(0)`
- Same salt string + same bytecode = same address on all EVM chains
- Change the salt string for new deployment rounds (e.g., `"v3-round1"` -> `"v3-round2"`)
- If bytecode changes (code update + recompile), the address changes even with the same salt

## Cross-Chain Deterministic Addresses

To get the same contract address on multiple chains:

1. Use the same `DEPLOY_SALT` on all chains
2. Compile with the same Solidity version and optimizer settings

The CREATE2 address is computed via the deterministic factory at `0x4e59b44847b379578588920cA78FbF26c0B4956C`.

## Contract Verification

Use `verify.sh` to verify deployed contracts on block explorers. It auto-detects the verifier type (Blockscout / Etherscan / Routescan) based on network.

```bash
./script/v3/verify.sh <ContractName> <DeployedAddress> <Network>
```

Examples:

```bash
# Blockscout (Orderly L2) — no API key needed
./script/v3/verify.sh LedgerImplA 0xf4D9...dCc3 orderly-testnet
./script/v3/verify.sh LedgerImplB 0xabcd...ef01 orderly

# Etherscan — requires chain-specific API key in .env
./script/v3/verify.sh Vault 0x1234...5678 arbitrum
./script/v3/verify.sh Vault 0x1234...5678 base

# Routescan (Avalanche, Mode, Sonic) — no API key needed
./script/v3/verify.sh Vault 0x1234...5678 avalanche
```

### Verifier Types by Network

| Type | Mainnet | Testnet | API Key |
|------|---------|---------|---------|
| **Blockscout** | `orderly`, `story` | `orderly-testnet`, `story-testnet`, `morph-testnet`, `mantle-testnet`, `sei-testnet` | Not needed |
| **Etherscan** | `arbitrum`, `optimism`, `polygon`, `base`, `ethereum`, `mantle`, `berachain`, `bsc` | `arbitrum-testnet`, `optimism-testnet`, `polygon-testnet`, `base-testnet`, `ethereum-testnet` | Required |
| **Routescan** | `avalanche`, `mode`, `sonic` | `avalanche-testnet`, `mode-testnet`, `sonic-testnet` | Not needed |

### Required API Keys (`.env`)

```bash
ETHERSCAN_API_KEY=""           # Ethereum
ARB_ETHERSCAN_API_KEY=""       # Arbitrum
OP_ETHERSCAN_API_KEY=""        # Optimism
POLYGON_ETHERSCAN_API_KEY=""   # Polygon
BASE_ETHERSCAN_API_KEY=""      # Base
MANTLE_ETHERSCAN_API_KEY=""    # Mantle
BERACHAIN_ETHERSCAN_API_KEY="" # Berachain
BSC_ETHERSCAN_API_KEY=""       # BSC
```

## Workflow Example

```bash
# 1. Predict addresses first
DEPLOY_SALT="orderly-v3-round1" \
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "predictAll()" --rpc-url orderly-testnet

# 2. Deploy to chain A
DEPLOY_SALT="orderly-v3-round1" \
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "runAll()" --rpc-url orderly-testnet --broadcast

# 3. Deploy to chain B (same addresses)
DEPLOY_SALT="orderly-v3-round1" \
forge script script/v3/DeployCreate2Impl.s.sol \
    --sig "runAll()" --rpc-url arbitrum --broadcast

# 4. Verify on each chain
./script/v3/verify.sh LedgerImplA 0xf4D9...dCc3 orderly-testnet
./script/v3/verify.sh LedgerImplA 0xf4D9...dCc3 arbitrum
```
