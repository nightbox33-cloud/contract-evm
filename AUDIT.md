# Auditoría de Seguridad — Orderly Network `contract-evm`

**Repositorio:** `nightbox33-cloud/contract-evm` (fork de `OrderlyNetwork/contract-evm`)
**Commit auditado:** `7ac1f70080e781a1c9e8c76778daa4bb2e1491c6` (`main`, synced through 2026‑09‑20)
**Rama de trabajo:** `arena/c8989870-contract-evm`
**Fecha:** 2026‑10‑30
**Alcance:** todo el código de `src/` (9.166 líneas Solidity) + scripts de despliegue y configuración
**Compilador:** `solc 0.8.26`, `evm_version = cancun`, optimizador `runs = 1000` (y `200`, la configuración oficial de `compiler_config.json`)

---

## 1. Resumen ejecutivo

Se auditó línea por línea el 100 % de los contratos de `src/` (Ledger y sus 5 implementaciones por `delegatecall`, OperatorManager + impls, OperatorManagerZip/DecompressorExtension, Vault, VaultManager, FeeManager, MarketManager, librerías de firma y de matemática de posiciones, Ed25519/SHA‑512, layout de almacenamiento y patrón proxy/upgradeable).

**Resultado:** el proyecto compila sin errores ni warnings relevantes (61 warnings de “parámetro sin usar”, todos en `Ledger.sol` y todos esperados por el patrón `delegatecall`). **No se encontró ninguna vulnerabilidad crítica explotable de forma permissionless por un tercero** en el superficie viva (depósito, vistas, `delegateSigner`). Los caminos que mueven dinero están protegidos por roles (`onlyOperatorManager`, `onlyCrossChainManager`, `onlyOwner`, `onlyLedger`, `onlyOperator`) y por firmas ECDSA/Ed25519 del motor y del usuario.

Sin embargo, sí se identificaron:

* **1 bug real de alta severidad (corrupción silenciosa de contabilidad)** en `LedgerImplB` — el camino de *upload* de trades en lote con *transient storage*. Hoy está **inerte** (el `OperatorManager` no lo enruta), pero **se activaría y corrompería posiciones de inmediato** si alguien descomenta la línea indicada en el propio código. **Verificado a nivel de codegen del compilador y corregido en esta rama.**
* **3 riesgos altos de modelo de confianza / centralización** (el `owner` de cada `Vault` puede vaciar el Vault completo de su cadena sin timelock ni límite on‑chain; el *swapOperator*/*swapSigner*; y el rol `SYMBOL_MANAGER_ROLE`).
* **5 hallazgos medios** (fee de retiro no cubierta por la firma del usuario; allowance colgante en `withdraw2Contract`; pérdida de fondos en `withdraw` cuando el pago falla pero el mensaje cross‑chain ya se envió; `rebalanceMint` acreditando un importe no verificado; colisión del *ring buffer* de rebalanceos).
* **7 hallazgos bajos / informativos** (replay entre `bizType` 1 y 7 por no cubrir `bizType` en la firma; `expirationTimestamp` fuera de la firma; `approve` residual en `rebalanceBurn`; `decompress()` público con `delegatecall` a sí mismo; `VaultEnum` no validado; sin *storage gap* en `Vault`; secreto de RPC en `.env.example`, etc.).

**Se aplicaron y compilaron 5 parches** (marcados en el código con `[AUDIT-FIX …]`), todos quirúrgicos y sin cambios de comportamiento para los flujos válidos:

| ID | Archivo | Parche |
|----|---------|--------|
| H‑01 | `src/LedgerImplB.sol` | `signextend` en todas las lecturas `int128` de *transient storage* |
| M‑01 | `src/vaultSide/Vault.sol` | reset de allowance tras `depositFromStrategy` en `withdraw2Contract` |
| L‑01 | `src/vaultSide/Vault.sol` + `IVault.sol` | `revert UnsupportedVaultType` para `vaultType` desconocido |
| L‑02 | `src/vaultSide/Vault.sol` | limpieza de allowance en `rebalanceBurn` (éxito y fallo) |
| L‑03 | `src/zip/DecompressorExtension.sol` + `OperatorManagerZip.sol` | `decompress()` restringido a `onlyOperator` |
| L‑04 | `src/vaultSide/Vault.sol` | `uint256[42] __gap` para upgrades seguros |

> **“0 riesgos” no es alcanzable por auditoría.** Lo que sí se entrega es: superficie permissionless limpia, todos los hallazgos identificados con evidencia y mitigación, y los 6 bugs/latentes corregidos en código. El riesgo residual que **no se puede eliminar con código** es el de administración (sección 4.1), que requiere controles operativos (multisig + timelock + límites).

**Limitación de verificación:** en este entorno no hay binario de Foundry disponible (la descarga de releases de GitHub está bloqueada) y los submódulos `lib/` no venían inicializados, por lo que **no se pudo ejecutar `forge test`**. Toda la verificación se hizo compilando el proyecto completo con `solc‑js 0.8.26` (0 errores) e inspeccionando el *assembly* generado. Se recomienda ejecutar `forge test` (y añadir los tests sugeridos en la sección 8) antes de desplegar los parches.

---

## 2. Metodología

1. **Inventario y mapa de confianza:** identificación de todos los contratos *proxy* (upgradeables), sus implementaciones y los roles/EOAs con privilegios.
2. **Revisión manual línea por línea** de los 100 % de los archivos de `src/`, con foco en: rutas de movimiento de fondos (Vault, VaultManager), autenticación de llamadas (`msg.sender`, firmas), aritmética con `int128/uint128` (overflow/underflow/signo), `delegatecall`, patrones de upgrade (colisión de slots), replay y dominios de firma, y ensamblador en línea.
3. **Compilación completa** con `solc 0.8.26` (cancun) y análisis de `warnings`, tamaños EIP‑170 y *assembly* generado.
4. **Verificación empírica del bug H‑01** inspeccionando el *legacy assembly* emitido por el compilador para confirmar que Solidity **no** normaliza (`SIGNEXTEND`) un `int128` leído desde ensamblador (sección 5.1).
5. **Modelado de atacante:** (a) externo permissionless, (b) operador/keeper comprometido, (c) motor (CEFI) comprometido, (d) `owner`/rol comprometido, (e) relayer cross‑chain comprometido.

---

## 3. Alcance y superficie de ataque

### 3.1 Contratos auditados

| Contrato | LOC | Custodia activos | Privilegios |
|---|---|---|---|
| `vaultSide/Vault.sol` | 881 | **Sí** (USDC/ERC20/ETH de usuarios) | owner, roles, crossChainManager, swapOperator |
| `Ledger.sol` | 711 | No | owner, roles, delegatecall a impls |
| `LedgerImplA/B/C/D/View.sol` | 2.703 | No (vía Ledger) | sin control de acceso propio (se invoca por `delegatecall`) |
| `OperatorManager.sol` + `ImplA/B` | 607 | No | operator EOA + operatorManagerZip |
| `VaultManager.sol` | 393 | No (contabilidad de saldos por cadena) | owner, roles, onlyLedger |
| `FeeManager.sol` | 87 | No | owner, roles |
| `MarketManager.sol` | 73 | No | owner, onlyOperatorManager, onlyLedger |
| `zip/OperatorManagerZip.sol` + `DecompressorExtension` | 481 | No | zipOperator, owner |
| `library/Signature.sol` | 967 | — | verificación ECDSA/Ed25519 |
| `library/Ed25519/*` | — | — | verificación de firmas Solana |
| `library/typesHelper/*`, `oz5Revised/*`, resto | ~1.500 | — | aritmética y control de acceso |

### 3.2 Funciones invocables **por cualquiera** (sin rol ni firma)

| Función | Contrato | Evaluación |
|---|---|---|
| `deposit`, `depositTo` | Vault | Correcto: `accountId == keccak(receiver, brokerHash)`, token/broker permitidos, límite de depósito, `safeTransferFrom` antes del mensaje cross‑chain |
| `delegateSigner` | Vault | Solo emite evento; exige `msg.sender` con código y `delegateSigner` sin código |
| `getDepositFee` | Vault | `view` |
| `decompressed`, `getData` | OperatorManagerZip | `view` (gas griefing acotado) |
| `decompress` | OperatorManagerZip | **`delegatecall` a sí mismo con calldata arbitraria** → ver L‑03 (parcheado: ahora `onlyOperator`) |
| `batchGetUserLedger*`, `getUser*` | Ledger | Lecturas (`delegatecall` al impl de vistas) |
| `initialize` | todos los proxies | Protegido: se pasa en el constructor del `TransparentUpgradeableProxy`; las impls tienen `_disableInitializers()` |

Conclusión: **la única función permissionless que mueve valor es `deposit`/`depositTo`**, y su validación es sólida (no hay forma de acreditar a un `accountId` ajeno pagando desde otra dirección, ni de saltarse el límite de depósito, ni de reentrar en un flujo que incremente saldo).

---

## 4. Hallazgos

Escala: **Crítico** = pérdida directa de fondos/permanente sin condiciones raras · **Alto** = pérdida de fondos o corrupción de estado con condiciones plausibles · **Medio** = pérdida parcial/condicionada, *griefing*, o degradación de garantías · **Bajo** = defensa en profundidad · **Info** = buenas prácticas.

### Tabla resumen

| ID | Severidad | Título | Estado |
|----|-----------|--------|--------|
| C‑01 | Crítico (centralización) | El `owner` del `Vault` puede vaciar el 100 % de los fondos de su cadena | Abierto — requiere control operativo |
| H‑01 | Alto | `LedgerImplB`: `int128` leído de *transient storage* sin extensión de signo → corrupción silenciosa de posiciones | **Parcheado** (latente, hoy inerte) |
| H‑02 | Alto | `delegateSwap`: `swapSigner`/`swapOperator` convierten al Vault en un *proxy* de llamadas arbitrarias | Abierto — diseño |
| H‑03 | Alto | `setAllowedSymbolByOperator` puede ser invocado por cualquier `SYMBOL_MANAGER_ROLE` sin firma CEFI | Abierto — revisar política de roles |
| M‑01 | Medio | Allowance colgante en `withdraw2Contract` (y `safeApprove(nonzero→nonzero)`) | **Parcheado** |
| M‑02 | Medio | `fee` del retiro **no** está firmada por el usuario; `maxWithdrawFee` por defecto = ilimitado | Abierto — requiere cambio off‑chain |
| M‑03 | Medio | `Vault.withdraw`: si el pago falla (blacklist/nativo) el mensaje cross‑chain ya se envió → el usuario es debitado sin cobrar | Abierto |
| M‑04 | Medio | `rebalanceMint`: en el `catch` se acredita `data.amount` sin verificar lo realmente acuñado | Abierto |
| M‑05 | Medio | `VaultManager`: *ring buffer* de 100 rebalanceos puede sobrescribir un estado `Pending` y congelar contabilidad | Abierto |
| L‑01 | Bajo | `withdraw2Contract` no revierte para `vaultType` no soportado (fondos quedan atrapados) | **Parcheado** |
| L‑02 | Bajo | `rebalanceBurn` deja `approve` residual al fallar `depositForBurn` | **Parcheado** |
| L‑03 | Bajo | `DecompressorExtension.decompress()` público con `delegatecall` a sí mismo | **Parcheado** |
| L‑04 | Bajo | `Vault` sin *storage gap* para upgrades | **Parcheado** |
| L‑05 | Bajo | `bizType` no forma parte del mensaje firmado → replay entre `Withdraw` (1) y `DelegateWithdraw` (7) | Abierto |
| L‑06 | Bajo | `delegateSwapWithExpiration`: la expiración la pone el *caller*, no el firmante | Abierto |
| L‑07 | Bajo | Secuencia estricta en `permissionlessListingSequenceId` + `EnumerableSetError` en no‑ops | Abierto |
| I‑01 | Info | `SwapSignature.sol` es código muerto e inconsistente (typehash `swapNonce` vs `tradeId`) | Abierto |
| I‑02 | Info | Firmas EIP‑191 (`toEthSignedMessageHash`) en lugar de EIP‑712 en uploads del motor | Abierto |
| I‑03 | Info | Margen EIP‑170 de `OperatorManagerImplB`: 264 bytes con `runs=200` | Abierto |
| I‑04 | Info | Credenciales/endpoints en `.env.example` (clave Infura + token de RPC) | Abierto |
| I‑05 | Info | `Ed25519.verify` no rechaza claves de orden pequeño/torsión | Abierto |
| I‑06 | Info | `Ledger`: funciones de lectura no son `view` (no se pueden usar en contexto `view`) | Abierto |
| I‑07 | Info | `_processEventUpload` construye calldata con `abi.encodePacked` y offsets calculados a mano | Abierto |

---

### 4.1 C‑01 — El `owner` del `Vault` puede vaciar todos los fondos de su cadena

**Severidad:** Crítico (riesgo de centralización, no *bug*)
**Ubicación:** `src/vaultSide/Vault.sol:191` (`setCrossChainManager`), `:306` (`changeTokenAddressAndAllow`), `:766` (`setSwapOperator`), `:771` (`setSwapSigner`), `:776` (`setVaultAdapter`)

**Descripción.**
El `Vault` es el único contrato que custodia valor real en cada cadena. Su `owner` (una sola clave EOA o multisig) puede, sin timelock ni límite on‑chain:

1. `setCrossChainManager(atacante)` y acto seguido llamar a `withdraw({tokenAmount: balanceTotal, fee: 0, receiver: atacante, …})`, que transfiere **cualquier** cantidad de **cualquier** token permitido a cualquier dirección. El `Vault` no comprueba nada sobre `accountId`/`brokerHash` en `withdraw`; toda la validación ocurre en el `Ledger` (otra cadena).
2. `setSwapOperator(owner)` + `setSwapSigner(owner)` y ejecutar `delegateSwap` con `to` y `swapCalldata` arbitrarios: `_internalDelegateSwap` hace `data.to.call{value: …}(data.swapCalldata)` desde el Vault. Esto también permite `transfer` de cualquier token del Vault.
3. `changeTokenAddressAndAllow(tokenHash, tokenFalso)` para redirigir un `tokenHash` a otro contrato.

Adicionalmente, el `owner` del `Ledger` puede `setLedgerImplA…View` (código arbitrario sobre toda la contabilidad), `setCrossChainManager` (que puede llamar a `accountDeposit` e inyectar saldo) y `setPrimeWallet`/`setValidVault` (redirigir retiros a contratos).

**Impacto.** Compromiso de una única clave ⇒ pérdida total de los fondos de los usuarios en esa cadena y, vía `Ledger`, capacidad de inflar saldos en toda la contabilidad.

**Recomendación (operativa, no de código).**
* `owner` de `Vault`, `Ledger`, `VaultManager`, `FeeManager`, `MarketManager` y `ProxyAdmin` **detrás de multisig** (p. ej. 4‑de‑7 con firmantes independientes) con **timelock ≥ 48 h**.
* Añadir on‑chain (si el modelo de negocio lo permite): `setCrossChainManager` con *two‑step* + delay, límite diario de salida por token, y `emergencyPause` sin capacidad de mover fondos.
* Verificar en el explorador que `owner()` de cada proxy en producción es un contrato multisig y no una EOA; documentar el proceso de rotación.
* Considerar `renounceOwnership`‑style inmutabilidad para `swapOperator`/`swapSigner` una vez configurados, o al menos `nonZeroAddress`.

---

### 4.2 H‑01 — `LedgerImplB`: `int128` sin extensión de signo al leer *transient storage*

**Severidad:** Alto (Crítico si se habilita el *batch upload*)
**Ubicación:** `src/LedgerImplB.sol:247‑280` (`_getTSSecondSlot`, `_getTSThirdSlot`, `_getTSFourthSlot`, `_getFeeTSFirstSlot`, `_getFeeTSSecondSlot`), consumido en `_executeProcessValidatedFutures` (`:74‑110`) y `_chargeFundingFee` (`:364`), expuesto por `Ledger.executeProcessValidatedFuturesBatch` (`src/Ledger.sol:367`).
**Estado:** **corregido en esta rama** (`[AUDIT-FIX H-01]`).

**Descripción.**
Los *getters* de *transient storage* devuelven valores `int128` así:

```solidity
function _getTSSecondSlot(bytes32 keyBase) internal view returns (int128 v1, int128 v2) {
    assembly {
        let tmp := tload(key)
        v1 := shr(128, tmp)          // ← NO sign-extend
        v2 := and(tmp, MASK_ALL_F)   // ← NO sign-extend
    }
}
```

Solidity **no** normaliza los valores que se escriben en una variable local desde ensamblador: el compilador asume que un `int128` en la pila está correctamente extendido a 256 bits (complemento a dos). Al leer los 128 bits altos de la palabra con `shr(128, …)` el valor queda **sin extensión de signo**: un `positionQty = -5` almacenado vuelve como `2¹²⁸ − 5` (un entero positivo gigantesco).

**Verificación empírica (codegen).** Se compiló un contrato mínimo con el mismo patrón y se inspeccionó el *legacy assembly*: la lectura se emite como `CALLDATALOAD; PUSH 0x80; SHR` **sin ningún `SIGNEXTEND`**, mientras que los argumentos `int128` sí reciben `PUSH 0x0f; SIGNEXTEND` al entrar. Es decir, el valor sucio llega tal cual a la aritmética posterior (`MUL`, `SDIV`, comparaciones de signo).

**Impacto concreto en el flujo de negocio.**
Las sumas y restas “sobreviven” (el truncamiento final a 128 bits al escribir en storage es un homomorfismo), pero **la multiplicación, la división y las comparaciones de signo no**:

* `_chargeFundingFee`: `positionQtyOld * (sumUnitaryFundings - lastSumUnitaryFundingsOld)` con `positionQtyOld` sucio ⇒ `accruedFee` basura **sin revert** ⇒ `costPosition` corrupto.
* `AccountTypePositionHelper.calAverageEntryPrice(positionQtyTmp, openingCostTmp, …)`: `openingCostOld * 1e8` y las ramas `positionQty * currentHolding > 0` / `qty * positionQty > 0` se evalúan con el signo equivocado ⇒ `averageEntryPrice` y `openingCost` incorrectos (o revert por `toUint128`).
* Todo ello se **escribe de vuelta** en `userLedger[...]` en `_writeBackTS`, es decir, la corrupción es persistente.

Cualquier cuenta con posición corta (`positionQty < 0`), `costPosition < 0`, `openingCost < 0` o *funding* negativo queda afectada en el primer lote. Es decir, prácticamente todas las cuentas activas.

**Por qué hoy no es explotable.** `OperatorManagerImplA` **no** enruta al camino *batch*: llama a `ledger.executeProcessValidatedFutures(trade)` por cada trade y deja comentado, con un `TODO` explícito (“Need audit of the following code”), el `executeProcessValidatedFuturesBatch`. `Ledger.executeProcessValidatedFuturesBatch` sí existe y es `onlyOperatorManager`, pero ningún contrato del `OperatorManager` lo invoca (verificado por `grep` en todo el repo).

**Corrección aplicada.** `signextend(15, …)` en cada lectura tipada como `int128` (15 = 16.º byte = frontera de 128 bits). Se dejaron intactas las lecturas `uint128` y `bool`.

**Test de regresión recomendado** (a añadir en `test/functionTest/PerpTradeUploadBatch.t.sol`):

```solidity
function test_batchUpload_negativePosition() public {
    // 1) posición corta existente: positionQty = -1e8, costPosition = -30_000e6, openingCost = -30_000e6
    // 2) lote con sumUnitaryFundings != lastSumUnitaryFundings y tradeQty != 0
    // 3) comparar el resultado de executeProcessValidatedFuturesBatch(...)
    //    contra N llamadas a executeProcessValidatedFutures(...) equivalente
    //    => deben ser idénticos, incluido costPosition, averageEntryPrice y openingCost
}
```

Recomendación adicional: mientras no exista ese test, **eliminar** `executeProcessValidatedFuturesBatch` del `Ledger` y del `ILedger` (o añadir `revert NotImplemented()`), para que nadie pueda habilitarlo por error.

---

### 4.3 H‑02 — `delegateSwap` da al binomio `swapOperator`/`swapSigner` control total de llamadas desde el Vault

**Severidad:** Alto
**Ubicación:** `src/vaultSide/Vault.sol:818‑870`, `src/library/DelegateSwapSignature.sol:10‑29`

**Descripción.**
```solidity
(bool success, bytes memory result) = data.to.call{value: value}(data.swapCalldata);
```
`data.to` y `data.swapCalldata` son arbitrarios y solo están validados por una firma de `swapSigner` (una EOA) y por el rol `onlySwapOperator` (otra EOA). Con ambos bajo una misma entidad, el Vault se convierte en un *proxy* de llamadas arbitrarias sobre todos sus tokens (el `safeApprove(data.to, inTokenAmount)` previo permite cualquier `transferFrom`).

Además, la firma **no** incluye `address(this)` (solo `block.chainid` y `tradeId`). Consecuencias:
* Si en el mismo chain coexisten dos `Vault` (p. ej. *multicollateral*), una firma válida para uno es válida para el otro (el `tradeId` se deduplica **por contrato**), pudiendo ejecutarse el mismo swap dos veces, cada una con el dinero de un Vault distinto.
* No hay caducidad dentro de la firma (ver L‑06) ni límite de importe.

**Impacto.** Compromiso de `swapSigner` **o** de `swapOperator` ⇒ drenaje total; firma reutilizada entre Vaults de la misma cadena ⇒ doble ejecución.

**Recomendación.**
```solidity
// DelegateSwapSignature.sol
bytes memory encoded = abi.encode(
    data.tradeId, block.chainid, address(this),   // ← añadir verifyingContract
    data.inTokenHash, data.inTokenAmount, data.to, data.value, data.swapCalldata,
    data.deadline                                  // ← añadir caducidad firmada
);
```
y migrar a EIP‑712 con `domainSeparator {name: "OrderlyVault", version: "1", chainId, verifyingContract}` (ya existe la infraestructura en `SwapSignature.sol`, hoy sin usar). Complementariamente: límite diario de salida por token, `to` en *whitelist*, y `swapOperator`/`swapSigner` en multisig. Nota: el cambio rompe el formato de firma ⇒ requiere coordinación off‑chain.

---

### 4.4 H‑03 — `setAllowedSymbolByOperator` no exige firma CEFI si el llamante tiene el rol

**Severidad:** Alto (según política de roles)
**Ubicación:** `src/VaultManager.sol:189‑204`, `src/OperatorManager.sol:246‑281`

**Descripción.** El *permissionless listing* se diseñó con dos candados: (a) el `OperatorManager` verifica firma CEFI + `sequenceId` estrictamente incremental + `chainId == block.chainid`, y (b) `VaultManager.setAllowedSymbolByOperator` exige `onlyOwnerOrRole(SYMBOL_MANAGER_ROLE)`. Pero (b) es un control **independiente**: cualquier dirección con `SYMBOL_MANAGER_ROLE` en `VaultManager` puede listar/deslistar símbolos arbitrarios **sin** pasar por (a) ni por el `operator`. Si ese rol se concede a una EOA de operaciones, el candado CEFI es decorativo.

**Impacto.** Listado de símbolos no autorizados (mercados que el motor no controla) ⇒ el motor podría subir trades de un símbolo sin mercado de precios, con `marketManager` sin `perpMarketCfg` ⇒ cálculos con mark price 0. También permite deslistar símbolos de forma abrupta (`revert SymbolNotAllowed` en settlements/liquidaciones ⇒ bloqueo de operaciones).

**Recomendación.** Restringir `setAllowedSymbolByOperator` a `onlyOwner` o a `msg.sender == operatorManagerAddress` (nuevo `onlyOperatorManager` en `VaultManager`), y dejar el rol `SYMBOL_MANAGER_ROLE` únicamente para `setMaxWithdrawFee`/`disableDepositToken`. Documentar quién tiene el rol en producción y verificarlo on‑chain.

---

### 4.5 M‑01 — Allowance colgante en `withdraw2Contract` (parcheado)

**Severidad:** Medio
**Ubicación:** `src/vaultSide/Vault.sol:563‑568` (original)
**Estado:** **corregido** (`[AUDIT-FIX M-01]`).

```solidity
tokenAddress.safeApprove(data.receiver, amount);
IProtocolVault(data.receiver).depositFromStrategy(data.clientId, data.brokerHash, address(tokenAddress), amount);
// ← nunca se resetea
```

**Impacto.**
1. Si el `ProtocolVault` (código de terceros, solo validado por `isValidVault` en el `Ledger`) no consume toda la allowance, el remanente queda activo indefinidamente y **cualquier** llamada posterior de ese contrato puede arrastrar tokens que pertenecen a otros usuarios del Vault.
2. En tokens tipo USDT (que revierten al pasar de allowance no nula a no nula), el segundo `withdraw2Contract` hacia el mismo receptor **revierte siempre** ⇒ retiros bloqueados para ese `receiver`. `SafeERC20.safeApprove` de OZ 4.8.2 exige `allowance == 0 || value == 0`.

**Corrección aplicada.** `tokenAddress.safeApprove(data.receiver, 0);` inmediatamente después de `depositFromStrategy`. Alternativa recomendada a futuro: patrón *pull* (el Vault transfiere y el `ProtocolVault` no necesita allowance) o `safeIncreaseAllowance` + reset garantizado al final del flujo. *(Nota: OZ 4.8.2 no tiene `forceApprove`; use `safeIncreaseAllowance`.)*

---

### 4.6 M‑02 — La `fee` del retiro no está firmada por el usuario y el tope por defecto es “ilimitado”

**Severidad:** Medio
**Ubicación:** `src/library/Signature.sol:53‑77` (`verifyWithdraw`), `:101‑124` (`verifyDelegateWithdraw`), `src/LedgerImplA.sol:103‑190`, `src/VaultManager.sol:31` (`maxWithdrawFee`, “default = unlimited”)

La firma EIP‑712 del usuario cubre:
```
Withdraw(string brokerId, uint256 chainId, address receiver, string token,
         uint256 amount, uint64 withdrawNonce, uint64 timestamp)
```
`fee` **no** está incluida. En la ejecución, el usuario es debitado por `tokenAmount` y recibe `tokenAmount - fee`; el `fee` va al `WithdrawFeeCollector`. El único límite es `maxWithdrawFee[tokenHash]`, que **por defecto es `0` = sin límite** y solo se fija por `setMaxWithdrawFee` (`onlyOwnerOrRole(SYMBOL_MANAGER_ROLE)`).

**Impacto.** Un motor/operador comprometido o con un bug puede fijar `fee = tokenAmount - 1` y el usuario recibe 1 unidad, con una firma que él autorizó por el importe completo. Idéntico en `verifyDelegateWithdraw`.

**Recomendación.**
* Corto plazo (on‑chain, sin cambios de ABI): **revertir** si `maxWithdrawFee[tokenHash] == 0` en el camino de retiro (obligar a configurar un tope explícito), o interpretar `0` como un tope por defecto conservador (p. ej. 5 USDC).
* Medio plazo: añadir `fee` al typehash firmado (requiere coordinación con CEFI y con el cliente).
* Añadir evento/alerta on‑chain cuando `fee > 0` y `fee` supere un umbral, para monitorización.

---

### 4.7 M‑03 — `Vault.withdraw`: el mensaje cross‑chain se envía antes de pagar; si el pago falla, el usuario pierde el saldo

**Severidad:** Medio
**Ubicación:** `src/vaultSide/Vault.sol:479‑520` (original)

```solidity
IVaultCrossChainManager(crossChainManagerAddress).withdraw(data);   // 1) mensaje "retiro OK" al Ledger
require(data.tokenAmount > data.fee, ...);
if (data.tokenHash == nativeTokenHash) {
    try this.attemptTransferNative(data.receiver, amount) { } catch {
        emit WithdrawFailed(address(0), data.receiver, amount);      // 2) se traga el fallo
    }
} else {
    ...
    if (!_validReceiver(data.receiver, address(tokenAddress))) {
        emit WithdrawFailed(address(tokenAddress), data.receiver, amount);  // 3) se traga el fallo
    } else { tokenAddress.safeTransfer(data.receiver, amount); }
}
```

**Impacto.** Cuando el pago no se realiza (receptor en *blacklist* de USDC, `receiver` que revierte al recibir ETH, token pausado), la transacción **no revierte**: el mensaje cross‑chain ya se envió, el `Ledger` ejecutará `accountWithDrawFinish` (quema el `frozenBalance` del usuario, acredita el fee al colector) y el saldo del usuario desaparece mientras los tokens siguen en el `Vault` sin contrapartida contable (`vaultManager` ya descontó el saldo). Los fondos quedan atrapados y el usuario pierde su saldo.

**Recomendación.** Invertir el orden: pagar primero (con `try/catch`) y solo enviar el mensaje cross‑chain si el pago tuvo éxito; en caso de fallo, no llamar al CC manager y revertir (o enviar explícitamente el mensaje de fallo, que ya existe: `accountWithdrawFail` vía `onlyOwner`). Como mínimo, no llamar a `IVaultCrossChainManager.withdraw()` antes de la transferencia. Nota: cambiar el orden altera la semántica de reintentos del CC manager; requiere coordinación con el equipo de cross‑chain, por eso **no se parcheó** aquí.

---

### 4.8 M‑04 — `rebalanceMint`: en el `catch` se acredita `data.amount` sin verificar lo acuñado

**Severidad:** Medio
**Ubicación:** `src/vaultSide/Vault.sol:690‑740` (original)

En el camino de éxito se mide el delta real (`balanceAfterMint - balanceBeforeMint`) y, para el modelo *normal*, se exige `== data.amount`. En el `catch` (solo `catch Error(string)`), si el motivo es exactamente `"Nonce already used"` se reporta `success = true` con **`amount: data.amount`** (valor del mensaje cross‑chain, no verificado). Idéntico problema si en el futuro CCTP cambia el texto del error o si el mensaje se recibió con un importe distinto (los fees del modelo *fast* se descuentan en el *burn*, no en el *mint*).

**Impacto.** Sobre‑acreditación de `tokenBalanceOnchain[mintChainId]` en el `VaultManager` ⇒ el `Ledger` permite retiros contra un saldo que no existe en el Vault ⇒ insolvencia parcial.

**Recomendación.** En el `catch` no acreditar cantidades: registrar el rebalanceo como `Fail` y dejar la reconciliación a un flujo administrativo explícito, o medir el delta real de balance en ambos caminos. Añadir también `catch (bytes memory)` para no dejar sin manejar los reverts con error personalizado.

---

### 4.9 M‑05 — `VaultManager`: el *ring buffer* de 100 rebalanceos puede sobrescribir un estado `Pending`

**Severidad:** Medio
**Ubicación:** `src/VaultManager.sol:44` (`MAX_REBALACE_SLOT = 100`), `:262`, `:271`, `:293`, `:310`

`rebalanceStatus[rebalanceId % 100]` se **sobrescribe** con cada nuevo `executeRebalanceBurn` sin comprobar si el slot pertenece a otro `rebalanceId` aún `Pending`. Si el rebalanceo `X` sigue pendiente (el mensaje cross‑chain aún no volvió) cuando llega `X+100`:

* el `burnFinish` de `X` revierte con `RebalanceIdNotMatch` para siempre;
* `tokenBurnFrozenBalanceOnchain` queda con el importe congelado permanentemente y `tokenBalanceOnchain` ya decrementado ⇒ **pérdida contable permanente** de esa cantidad (el Vault sigue teniendo los tokens, pero el `Ledger` los da por quemados).

**Recomendación.** Guardar el estado en un `mapping(uint64 => RebalanceStatus)` (coste de gas despreciable en una operación administrativa) o revertir si el slot está ocupado por otro `rebalanceId` distinto. Añadir además una función de reconciliación `onlyOwner` para cancelar un rebalanceo atascado.

---

### 4.10 L‑01 — `withdraw2Contract` no revierte para `vaultType` no soportado (parcheado)

**Severidad:** Bajo
**Ubicación:** `src/vaultSide/Vault.sol:563‑570` (original)
**Estado:** **corregido** (`[AUDIT-FIX L-01]`, nuevo error `UnsupportedVaultType` en `IVault`).

El `if / else if` no tenía rama `else`. Con `vaultType == VaultTypes.VaultEnum.UserVault (1)` no se pagaba nada, pero el mensaje cross‑chain ya se había enviado ⇒ mismo efecto que M‑03 (usuario debitado, fondos atrapados). Hoy el `Ledger` (`LedgerImplD._validateEvmReceiver`, `:242‑268`) bloquea ese caso con `revert NotImplemented()`; ahora el `Vault` también (defensa en profundidad).

---

### 4.11 L‑02 — `rebalanceBurn` deja allowance residual (parcheado)

**Severidad:** Bajo
**Ubicación:** `src/vaultSide/Vault.sol:663` (original)

`IERC20(burnToken).approve(tokenMessengerContract, data.amount)` seguido de un `try/catch` que **se traga** el fallo: si `depositForBurn` revierte, la allowance sobrevive. Hoy el spender es el `TokenMessenger` de Circle (de confianza), pero el patrón es frágil y además usa `approve` crudo (no `safeApprove`) ⇒ con tokens no estándar el retorno `false` se ignora silenciosamente.

**Corrección aplicada.** `approve(tokenMessengerContract, 0)` al final del flujo (éxito y fallo). Recomendado además: usar `SafeERC20.safeApprove`/`safeIncreaseAllowance` (OZ 4.8.2 no incluye `forceApprove`) y comprobar el `bool` de retorno de `approve` para tokens no estándar.

---

### 4.12 L‑03 — `DecompressorExtension.decompress()` público ejecuta `delegatecall` a sí mismo (parcheado)

**Severidad:** Bajo
**Ubicación:** `src/zip/DecompressorExtension.sol:90`, heredado por `OperatorManagerZip`
**Estado:** **corregido** (`[AUDIT-FIX L-03]`).

```solidity
function decompress(bytes calldata data) external payable {
    _delegatecall(decompressed(data));   // delegatecall(gas(), address(this), …) con calldata del llamante
}
```

Cualquiera puede descomprimir bytes arbitrarios y forzar un `delegatecall` al propio contrato con ese calldata. En el estado actual **no** escala privilegios (`delegatecall` preserva `msg.sender`, así que los `onlyOperator`/`onlyOwner` siguen aplicando y no hay `fallback`), pero es una primitiva peligrosa: cualquier función futura sin control de acceso, o un `receive`/`fallback` añadido, sería alcanzable trivialmente; además permite *griefing* de gas/memoria (hasta `2²⁰` SLOADs vía `getData`).

**Corrección aplicada.** `decompress` pasa a `virtual` en la base y `OperatorManagerZip` lo sobrescribe con `onlyOperator`. Alternativa: eliminar la función (nadie la usa: el *operator* usa `decodeFuturesTradeUploadData`/`decodeEventUploadData`).

---

### 4.13 L‑04 — `Vault` sin *storage gap* (parcheado)

**Severidad:** Bajo
**Ubicación:** `src/vaultSide/Vault.sol` (declaración de estado)

`Ledger` y `OperatorManager` reservan `uint256[36]` / `uint256[37]` de `__gap`, pero `Vault` —el contrato con más historial de upgrades y que custodia los fondos— no reservaba ninguno: la seguridad de cada upgrade depende de una disciplina *append‑only* estricta y de que nadie inserte una variable en medio (p. ej. junto a `tokenMessengerContract`).

**Corrección aplicada.** `uint256[42] private __gap;` al final del bloque de estado (no altera los slots existentes). Regla: las variables nuevas van **antes** del gap y se reduce su tamaño en consecuencia.

---

### 4.14 L‑05 — `bizType` no forma parte del mensaje firmado

**Severidad:** Bajo
**Ubicación:** `src/library/Signature.sol:414‑470` (`eventsUploadEncodeHash`), `src/OperatorManagerImplB.sol:44‑77`

`eventsUploadEncodeHash` clasifica cada evento por `bizType` y lo decodifica en una estructura tipada; el `bizType` en sí **no** se incluye en el payload firmado. `bizType == 1` (Withdraw → `executeWithdrawAction`, verifica firma ECDSA del usuario) y `bizType == 7` (DelegateWithdraw → `executeDelegateWithdrawAction`, verifica la firma del *delegate signer*) producen **exactamente el mismo** `WithdrawDataSignature` y caen en el mismo array. Por tanto una carga firmada para `bizType 1` puede reenviarse como `bizType 7` (y viceversa) y ejecutar la otra ruta.

**Impacto.** Requiere que el atacante controle el *relayer*/*operator* que envía el `eventUpload` (o que intercepte la carga antes de su inclusión). El daño se limita a que la ruta alternativa aplica sus propias comprobaciones (la mayoría terminan en `state != 0` ⇒ evento de fallo sin mover fondos), pero rompe la garantía de que un evento firmado para una operación se ejecute como esa operación.

**Recomendación.** Incluir `bizType` en el *struct* firmado (`abi.encode(bizType, …)`) y/o decodificar siempre `data` a la estructura estricta del `bizType` declarado y comparar el re‑encode.

---

### 4.15 L‑06 — `delegateSwapWithExpiration`: la expiración la elige el llamante

**Severidad:** Bajo
**Ubicación:** `src/vaultSide/Vault.sol:829‑837`

```solidity
function delegateSwapWithExpiration(VaultTypes.DelegateSwap calldata data, uint256 expirationTimestamp)
    external whenNotPaused onlySwapOperator nonReentrant
{
    if (block.timestamp > expirationTimestamp) revert SwapExpired(...);
```
`expirationTimestamp` es un parámetro del **llamante** (`swapOperator`), no del firmante (`swapSigner`). No aporta ninguna garantía: el operador pasa siempre un valor futuro. Debe ir dentro de la estructura firmada.

---

### 4.16 L‑07 — Listado permissionless: secuencia estricta y no‑ops que revierten

**Severidad:** Bajo
**Ubicación:** `src/OperatorManager.sol:246‑281`, `src/VaultManager.sol:189‑204`

* `_sequenceId` debe ser **exactamente** `permissionlessListingSequenceId + 1`: un hueco (p. ej. CEFI emite 5 y on‑chain está en 3) bloquea la función hasta que se envíe el 4, que quizá nunca se firmó ⇒ **bloqueo permanente** del listado permissionless.
* `VaultManager.setAllowedSymbolByOperator` revierte con `EnumerableSetError` si la operación es un no‑op (añadir algo ya añadido o quitar algo ya quitado) ⇒ un reintento idempotente desde CEFI revierte siempre.

**Recomendación.** Aceptar `_sequenceId >= expected` (con emisión del salto) y tratar los no‑ops como éxito (`succ == false` ⇒ `emit` y `return`), o exponer un `onlyOwner` de recuperación para fijar `permissionlessListingSequenceId`.

---

### 4.17 Informativos

* **I‑01 `SwapSignature.sol` es código muerto e inconsistente.** No se usa en ningún sitio (verificado con `grep`). Su `DELEGATE_SWAP_TYPEHASH` declara `uint256 swapNonce` pero codifica `data.tradeId`. Si alguien lo conectara por error, el digest no sería interoperable. **Eliminarlo** o corregirlo.
* **I‑02 Firmas EIP‑191.** Los *uploads* del motor y las firmas de swap usan `toEthSignedMessageHash` (prefijo `"\x19Ethereum Signed Message"`) en vez de EIP‑712. Funciona, pero impide que el firmante vea campos estructurados en su *wallet* (riesgo de *phishing* de firmas) y no incluye `chainId`/`verifyingContract` en el caso de `perpUpload`/`eventsUpload` (protección sólo por `batchId` monotónico).
* **I‑03 Margen EIP‑170.** Con la configuración oficial (`runs = 200`): `OperatorManagerImplB` = **24.312 bytes** (límite 24.576 ⇒ **264 bytes de margen**), `LedgerImplA` = 23.449, `LedgerImplC` = 23.176, `Vault` = 21.841 (`runs=1000`: 24.579 / 24.367 / 24.123 / 23.652, y `OperatorManagerImplB` **excede** el límite). Cualquier añadido a `OperatorManagerImplB` puede hacerlo no desplegable. Verificar el `runs` usado en el despliegue real.
* **I‑04 Credenciales en `.env.example`.** Contiene una API key de Infura (`eda7ae04091a465eb960308cb44bf0b3`) y un endpoint privado de Orderly con token en la ruta (`…/fVgSf4ruGhwvEMd8z6dRwsH6XgRaq31wxN4tRhZPN6rWYhjVt/rpc`). Son de testnet, pero deben rotarse/eliminarse: el repo es público.
* **I‑05 `Ed25519.verify` no rechaza claves de orden pequeño.** La verificación comprueba `s < L` y descomprime `k`, pero no rechaza puntos de torsión/identidad como clave pública. En este sistema el `pubkey` de Solana se fija al crear la cuenta (`accountId == keccak(pubkey, brokerHash)`) y la ruta (`executeWithdrawSolAction`) es `onlyOperatorManager`, por lo que **no es explotable**, pero conviene añadir la comprobación (evita “cualquier firma válida” para claves degeneradas).
* **I‑06 Funciones de lectura no `view` en `Ledger`.** `getFrozenWithdrawNonce`, `batchGetUserLedger`, `batchGetUserBalance`, `getUserTotalFrozenBalance`, `getUserEscrowBalance`, `getBalanceTransferState` no son `view` (hacen `delegatecall`), por lo que no pueden invocarse desde otro contrato en contexto `view` ni desde `eth_call` de forma garantizada por herramientas estrictas. Recomendación: `staticcall` + `view`.
* **I‑07 `_processEventUpload` construye calldata a mano.** `abi.encodePacked(selector, …, abi.encode(eventId), dataWithoutOffset)` con `eventOffset` calculado a mano. Es correcto hoy, pero cualquier cambio de firma/orden de parámetros en el `Ledger` produce corrupción silenciosa de calldata. Recomendación: `abi.encodeCall(ILedger.executeX, (decodedStruct, eventId))` con decodificación tipada por `bizType`.

---

## 5. Revisión por área (qué se verificó y por qué está bien)

### 5.1 Patrón proxy / `delegatecall` / layout de almacenamiento
* **`Ledger` ↔ `LedgerImplA/B/C/D/View`:** ambos heredan `OwnableUpgradeable` (que incluye `Initializable`) **en el mismo orden** y después `LedgerDataLayout`; `AccessControlRevised` usa almacenamiento *namespaced* ERC‑7201 (`0x02dd7b…`), que no colisiona. Las direcciones de las impls viven en un slot propio (`0x220427b0…`). **Layout consistente.**
* **`OperatorManager` ↔ `ImplA/B`:** mismo razonamiento con `OperatorManagerDataLayout`. **Consistente.**
* **`LedgerDataLayout`:** el `__gap` se redujo de 37 a 36 al añadir `calAvgSkipList` — la aritmética es correcta (1 mapping = 1 slot). **Consistente.**
* **`LedgerImplB` y *transient storage*:** los slots transitorios viven en el contexto del proxy (el `delegatecall` los preserva durante la transacción) y se limpian en `_writeBackTS`/`_cleanUpFeeCollector`. Riesgo residual: colisión de claves entre el namespace de posiciones (`keccak256(accountId, symbol) & ~0xff | n`) y el flag de `marketManager` (usa `symbolHash` crudo); la probabilidad es despreciable, pero conviene *namespear* también el flag.
* **`OperatorManagerZip`:** `bytes32[2²⁰] private _dict` se declara **antes** de `OperatorManagerZipDataLayout`, por lo que este último empieza en el slot 1.048.577 (1 + 2²⁰). Es consistente mientras `E` se mantenga en la misma posición de la lista de herencia (nunca insertar bases nuevas antes).
* **Inicialización:** todos los proxies se despliegan con `initialize()` en los argumentos del constructor del `TransparentUpgradeableProxy` (sin ventana de *front‑running*), y todas las impls llaman `_disableInitializers()` en el constructor.

### 5.2 Aritmética y contabilidad
* `SafeCastHelper.toInt128/toUint128` protegen los casteos `uint128 ↔ int128`; las sumas/restas de saldos usan `checked arithmetic` de 0.8.26 (un underflow revierte, no corrompe).
* `chargeFundingFee` redondea hacia arriba el remanente a favor del protocolo; `halfUp/halfDown` manejan correctamente los signos y `abs(int128.min)` está protegido (`1 << 127`).
* `calAverageEntryPrice` opera en `int256` y castea al final; la variante `tryCalAverageEntryPrice` (usada en la *skip list*) reporta el desbordamiento en vez de revertir.
* `frozenBalance` / `finishFrozenBalance` / `unfrozenBalance` son simétricos y `FrozenBalanceInconsistent()` garantiza que no queden restos. `lastWithdrawNonce` se actualiza dentro de `frozenBalance`, lo que impide el *replay* de un `withdrawNonce`.
* `escrowBalances` (transferencias internas) se descuenta del saldo disponible antes de permitir un retiro, y se libera en `_finalizeTransfer`; la lógica `Debit/Credit/Both` impide el doble abono.
* `executeSettlement` verifica `totalSettleAmount == settledAmount`; `executeLiquidation*`/`executeAdl*` validan `|positionQtyTransfer| <= |userPositionQty|`.

### 5.3 Control de acceso
* Todos los *setters* de `Vault`, `Ledger`, `VaultManager`, `FeeManager`, `MarketManager` son `onlyOwner`/`onlyOwnerOrRole`.
* `Ledger` re‑implementa `grantRole`/`revokeRole` como `onlyOwner` (no dependen de `_roles[role].adminRole`, que sería `DEFAULT_ADMIN_ROLE` y que nadie tiene ⇒ sin esta redefinición el control de acceso estaría roto; está bien resuelto).
* `VaultManager`/`MarketManager`/`FeeManager` están atados a `Ledger`/`OperatorManager` con `onlyLedger`/`onlyOperatorManager`.
* No hay `selfdestruct`, `tx.origin` ni `delegatecall` a direcciones controladas por el usuario en ningún contrato de custodia.

### 5.4 Verificación de firmas
* `ECDSA.recover` de OZ 4.8.2 rechaza firmas con `s` alto (no maleables) y `v` inválido.
* `verifyWithdraw` incluye `chainId` (en el dominio y en el *struct*) y `address(this)` (Ledger) en el dominio EIP‑712 ⇒ no hay replay entre cadenas ni entre contratos.
* `withdrawNonce` + `lastWithdrawNonce` ⇒ sin replay dentro de la cuenta.
* `permissionlessListing` ata `symbolHash`, `allowed`, `sequenceId` y `chainId`, y comprueba `_chainId == block.chainid`.
* `verifyWithdrawSol` acepta dos codificaciones (mensaje directo o transacción *wrapped* de Solana); `Ed25519` verifica `s < L` y la ecuación del grupo.

### 5.5 Superficie de depósito (la única permissionless con valor)
* `accountId` se valida contra `keccak(receiver, brokerHash)` (o `keccak(vault, sender, brokerHash)` solo si `msg.sender == vaultAdapter`) ⇒ no se puede acreditar a una cuenta ajena.
* `brokerHash` debe estar permitido; `tokenHash` permitido y no deshabilitado; `tokenAmount > 0`; límite de depósito opcional.
* `safeTransferFrom` **antes** del mensaje cross‑chain (mitiga reentrancy de tokens), y el `Vault` no tiene estado propio que un token malicioso pueda manipular a mitad de función.
* Para el token nativo, se exige `msg.value >= tokenAmount` y se imputa el excedente a la comisión cross‑chain.
* `depositId` monotónico por `++`, sin huecos.

---

## 6. Cambios realizados en esta rama

```
src/LedgerImplB.sol                 | signextend(15, …) en 5 getters de transient storage   [H-01]
src/vaultSide/Vault.sol             | allowance reset en withdraw2Contract                  [M-01]
                                    | revert UnsupportedVaultType en withdraw2Contract       [L-01]
                                    | allowance reset en rebalanceBurn                      [L-02]
                                    | uint256[42] __gap                                     [L-04]
src/interface/IVault.sol            | nuevo error UnsupportedVaultType                       [L-01]
src/zip/DecompressorExtension.sol   | decompress() → virtual                                 [L-03]
src/zip/OperatorManagerZip.sol      | override decompress() con onlyOperator                 [L-03]
```

**Verificación:** compilación completa de `src/` con `solc 0.8.26` (`evmVersion: cancun`), `runs = 1000` y `runs = 200` ⇒ **0 errores**. Tamaños con `runs = 200` (configuración oficial): antes → después
`Vault` 21.475 → **21.841** (+366), `OperatorManagerZip` 12.471 → **12.516** (+45), `LedgerImplB` 6.319 (sin cambio), `OperatorManagerImplB` 24.312 (sin cambio). Todos por debajo de 24.576.

**No se modificó** nada relacionado con: formatos de firma, orden de las llamadas cross‑chain, `maxWithdrawFee`, `bizType`, `rebalanceMint`, el *ring buffer* de rebalanceos ni los roles; todos esos cambios exigen coordinación off‑chain y se documentan como recomendación.

---

## 7. Riesgo residual y checklist de despliegue

1. **Roles:** verificar on‑chain que `owner()` de cada proxy es un multisig, que `operatorAddress`/`zipOperatorAddress`/`swapOperator` son EOAs dedicadas (no compartidas con otras funciones) y que `SYMBOL_MANAGER_ROLE`/`BROKER_MANAGER_ROLE` no estén en EOAs de operaciones.
2. **Timelock:** `ProxyAdmin.owner()` y `owner()` de `Vault`/`Ledger` con retardo ≥ 48 h para upgrades y cambios de `crossChainManager`.
3. **`maxWithdrawFee`:** fijar un tope explícito por token en cada cadena (hoy `0` = ilimitado).
4. **`OperatorManager.setOperatorManagerZipAddress`:** si no se usa el `zip`, dejarlo en `address(0)`; si se usa, el contrato `OperatorManagerZip` debe tener su `zipOperatorAddress` dedicado.
5. **No habilitar** `executeProcessValidatedFuturesBatch` hasta que exista el test diferencial de la sección 4.2.
6. **Monitorización on‑chain:** alertas sobre `ChangeCrossChainManager`, `ChangeOperator`, `ChangeLedgerImpl*`, `PrimeWalletSet`, `VaultSet`, `SetAllowedSymbol`, `WithdrawFailed`, `CalAverageEntryPriceSkipped` y `RebalanceBurnResult`.
7. **`forge test`** completo (con `--profile ci`, `fuzz_runs = 100_000`) sobre esta rama antes de cualquier despliegue; el entorno de auditoría no disponía de Foundry.

---

## 8. Tests de regresión recomendados

| Hallazgo | Test |
|---|---|
| H‑01 | Diferencial `executeProcessValidatedFuturesBatch` vs. N × `executeProcessValidatedFutures` con posiciones cortas, `costPosition`/`openingCost` negativos y *funding* negativo (fuzz). |
| M‑01 | `withdraw2Contract` con un `ProtocolVault` que consume solo la mitad (`assert token.allowance(vault, receiver) == 0`). |
| M‑02 | Fuzz: `fee <= tokenAmount-1` con `maxWithdrawFee == 0` ⇒ documentar/limitar. |
| M‑03 | `withdraw` con `receiver` en *blacklist* ⇒ debe revertir y no dejar el `frozenBalance` quemado. |
| M‑04 | `rebalanceMint` con `receiveMessage` que revierte `"Nonce already used"` y `data.amount` distinto del acuñado. |
| M‑05 | 101 rebalanceos con el primero pendiente ⇒ el estado no debe quedar inaccesible. |
| L‑05 | Reenviar un `eventUpload` firmado con `bizType 1` como `bizType 7` ⇒ debe rechazarse. |
| L‑03 | `decompress` desde una dirección que no es el `operator` ⇒ `OnlyOperatorCanCall`. |

---

## 9. Conclusión

El código está **bien estructurado para un sistema de este tamaño**: separación de responsabilidades por `delegatecall` (con layouts de almacenamiento consistentes), doble verificación (rol + firma criptográfica) en todas las rutas que mueven valor, aritmética con *checked math* y librerías de casteo seguro, y snapshots de estado (`escrowBalances`) para las transferencias internas asíncronas.

**No se encontró un vector de drenaje permissionless.** Los riesgos reales, en orden de impacto, son:

1. **Centralización (C‑01):** una sola clave `owner` puede vaciar el `Vault` de su cadena. Es el riesgo número uno y no se resuelve con código en este repo: requiere multisig + timelock + límites. **“0 riesgos” no es una afirmación honesta mientras esto no se mitigue operativamente.**
2. **Camino latente roto (H‑01):** corregido y verificado; no debe habilitarse el *batch upload* sin el test diferencial.
3. **Confianza en el motor/operador (M‑02, L‑05):** la firma del usuario no cubre la comisión y el `bizType` no está autenticado; ambos requieren cambios coordinados con CEFI.
4. **Manejo de fallos de pago (M‑03, L‑01) y de rebalanceo (M‑04, M‑05):** degradan la contabilidad en escenarios concretos; todos tienen mitigación clara y acotada.

Los parches aplicados (`[AUDIT-FIX …]`) son quirúrgicos, compilan y no cambian la semántica de los flujos válidos.
