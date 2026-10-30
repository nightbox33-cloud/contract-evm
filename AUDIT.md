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

**Resultado:** el proyecto compila sin errores ni warnings relevantes (61 warnings de “parámetro sin usar”, todos en `Ledger.sol` y todos esperados por el patrón `delegatecall`).

**Se encontró, y se demostró con bytecode en ejecución, una vulnerabilidad crítica (C‑02, sección 4.2).** `OperatorManagerImplB._processEventUpload` arma a mano la calldata que ejecuta el `Ledger` con `abi.encodePacked`, **descartando la palabra de cabecera ABI** del blob, mientras que la firma del motor se calcula sobre `abi.decode(blob, (T))`, que **sí** honra esa cabecera. Un mismo blob de bytes se decodifica como un evento benigno para el motor (y su firma valida) y como un evento arbitrario para el `Ledger` (y se ejecuta). La PoC ejecutada sobre EVM (sección 4.2.3) muestra el mismo blob firmado como un *settle* de **1 wei** y ejecutado como un *settle* de **1.000.000 USDC** a favor de una cuenta del atacante. Con eso, quien controla la clave `operator` —el componente caliente que transmite los lotes, precisamente el rol que la firma del motor debía impedir que pudiera fabricar eventos— puede acuñar saldo interno ilimitado, vaciar el fondo de seguros y retirar el USDC del `Vault` hasta agotarlo. Afecta a los **8 `bizType` dinámicos** (retiros, settlements, liquidaciones).

En el resto de la superficie **no se encontró ningún vector de drenaje permissionless** (depósito, vistas, `delegateSigner`): los caminos que mueven dinero están protegidos por roles (`onlyOperatorManager`, `onlyCrossChainManager`, `onlyOwner`, `onlyLedger`, `onlyOperator`) y por firmas ECDSA/Ed25519 del motor y del usuario.

Además se identificaron:

* **1 bug real de alta severidad (corrupción silenciosa de contabilidad)** en `LedgerImplB` — el camino de *upload* de trades en lote con *transient storage*. Hoy está **inerte** (el `OperatorManager` no lo enruta), pero **se activaría y corrompería posiciones de inmediato** si alguien descomenta la línea indicada en el propio código. **Verificado a nivel de codegen del compilador y corregido en esta rama.**
* **3 riesgos altos de modelo de confianza / centralización** (el `owner` de cada `Vault` puede vaciar el Vault completo de su cadena sin timelock ni límite on‑chain; el *swapOperator*/*swapSigner*; y el rol `SYMBOL_MANAGER_ROLE`).
* **5 hallazgos medios** (fee de retiro no cubierta por la firma del usuario; allowance colgante en `withdraw2Contract`; pérdida de fondos en `withdraw` cuando el pago falla pero el mensaje cross‑chain ya se envió; `rebalanceMint` acreditando un importe no verificado; colisión del *ring buffer* de rebalanceos).
* **7 hallazgos bajos / informativos** (replay entre `bizType` 1 y 7 por no cubrir `bizType` en la firma; `expirationTimestamp` fuera de la firma; `approve` residual en `rebalanceBurn`; `decompress()` público con `delegatecall` a sí mismo; `VaultEnum` no validado; sin *storage gap* en `Vault`; secreto de RPC en `.env.example`, etc.).

**Se aplicaron y compilaron 6 parches** (marcados en el código con `[AUDIT-FIX …]`), todos quirúrgicos y sin cambios de comportamiento para los flujos válidos:

| ID | Archivo | Parche |
|----|---------|--------|
| **C‑02** | `src/OperatorManagerImplB.sol` | **pin de la cabecera ABI (`== 0x20`) antes de re‑ensamblar la calldata: firma y ejecución decodifican el mismo struct** |
| H‑01 | `src/LedgerImplB.sol` | `signextend` en todas las lecturas `int128` de *transient storage* |
| M‑01 | `src/vaultSide/Vault.sol` | reset de allowance tras `depositFromStrategy` en `withdraw2Contract` |
| L‑01 | `src/vaultSide/Vault.sol` + `IVault.sol` | `revert UnsupportedVaultType` para `vaultType` desconocido |
| L‑02 | `src/vaultSide/Vault.sol` | limpieza de allowance en `rebalanceBurn` (éxito y fallo) |
| L‑03 | `src/zip/DecompressorExtension.sol` + `OperatorManagerZip.sol` | `decompress()` restringido a `onlyOperator` |
| L‑04 | `src/vaultSide/Vault.sol` | `uint256[42] __gap` para upgrades seguros |

> **“0 riesgos” no es alcanzable por auditoría.** Lo que sí se entrega es: superficie permissionless limpia, todos los hallazgos identificados con evidencia y mitigación, y los 7 bugs/latentes corregidos en código (incluido el crítico C‑02). El riesgo residual que **no se puede eliminar con código** es el de administración (sección 4.1), que requiere controles operativos (multisig + timelock + límites).

**Limitación de verificación:** en este entorno no hay binario de Foundry disponible (la descarga de releases de GitHub está bloqueada) y los submódulos `lib/` no venían inicializados, por lo que **no se pudo ejecutar `forge test`**. La verificación se hizo (a) compilando el proyecto completo con `solc‑js 0.8.26` (0 errores), (b) inspeccionando el *assembly*/*storage layout* generados y (c) **ejecutando bytecode real en una EVM local (`py‑evm`/`eth‑tester`)** para la PoC de C‑02, que es la evidencia más fuerte del informe. Los tests de la sección 8 (incluido `test/security/CalldataMismatch.t.sol`) están escritos y **compilan**, pero deben ejecutarse con `forge test` en CI antes de desplegar.

---

## 2. Metodología

1. **Inventario y mapa de confianza:** identificación de todos los contratos *proxy* (upgradeables), sus implementaciones y los roles/EOAs con privilegios.
2. **Revisión manual línea por línea** de los 100 % de los archivos de `src/`, con foco en: rutas de movimiento de fondos (Vault, VaultManager), autenticación de llamadas (`msg.sender`, firmas), aritmética con `int128/uint128` (overflow/underflow/signo), `delegatecall`, patrones de upgrade (colisión de slots), replay y dominios de firma, y ensamblador en línea.
3. **Compilación completa** con `solc 0.8.26` (cancun) y análisis de `warnings`, tamaños EIP‑170 y *assembly* generado.
4. **Verificación empírica del bug H‑01** inspeccionando el *legacy assembly* emitido por el compilador para confirmar que Solidity **no** normaliza (`SIGNEXTEND`) un `int128` leído desde ensamblador (sección 5.1).
5. **Ejecución de PoC sobre EVM:** para C‑02 se replicaron los dos decodificadores exactos del repo, se compilaron con `solc 0.8.26` y se desplegaron en `py‑evm`/`eth‑tester` para demostrar la divergencia y validar el parche (antes/después).
6. **Modelado de atacante:** (a) externo permissionless, (b) operador/keeper comprometido, (c) motor (CEFI) comprometido, (d) `owner`/rol comprometido, (e) relayer cross‑chain comprometido.

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

> **Matiz importante (C‑02):** «permissionless» no es la única dimensión. El hallazgo crítico de este informe **no** es permissionless —exige la clave `operator`— pero atraviesa el límite de confianza que la firma del motor define, que es el control de integridad del sistema. Una auditoría que solo mire la superficie permissionless lo deja pasar (y es lo que ocurrió en la primera pasada de esta misma revisión).

---

## 4. Hallazgos

Escala: **Crítico** = pérdida directa de fondos/permanente sin condiciones raras · **Alto** = pérdida de fondos o corrupción de estado con condiciones plausibles · **Medio** = pérdida parcial/condicionada, *griefing*, o degradación de garantías · **Bajo** = defensa en profundidad · **Info** = buenas prácticas.

### Tabla resumen

| ID | Severidad | Título | Estado |
|----|-----------|--------|--------|
| C‑01 | Crítico (centralización) | El `owner` del `Vault` puede vaciar el 100 % de los fondos de su cadena | Abierto — requiere control operativo |
| **C‑02** | **Crítico** | **`_processEventUpload` ejecuta un evento distinto del que firma el motor (discrepancia calldata ↔ firma): 8 `bizType` dinámicos falsificables por el `operator`** | **Parcheado** + PoC ejecutada |
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
| I‑07 | Info | `_processEventUpload` construye calldata con `abi.encodePacked` y offsets calculados a mano | **Re‑graduado → C‑02, parcheado** |

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

### 4.2 C‑02 — `_processEventUpload` ejecuta un evento **distinto** del que firma el motor (discrepancia calldata ↔ firma) — **CRÍTICO** *(nuevo, verificado con bytecode)*

**Archivos:** `src/OperatorManagerImplB.sol:44‑73` · `src/library/Signature.sol:414‑520` (`eventsUploadEncodeHash`) · `src/LedgerImplA.sol:237` (`executeSettlement`) · `src/LedgerImplA.sol` (`executeWithdrawAction`)

**Estado:** **parcheado** en esta rama (`[AUDIT-FIX C-02]`, `src/OperatorManagerImplB.sol`), verificado con la PoC de C.2.3. El endurecimiento de esquema recomendado en C.2.5 (firmar los bytes crudos) sí requiere coordinación con CEFI y queda como recomendación.

#### C.2.1 Causa raíz: dos decodificadores ABI distintos sobre los mismos bytes

La firma del motor **no** cubre el blob de bytes: cubre los **campos ya decodificados** de cada evento. En `Signature.eventsUploadEncodeHash`:

```solidity
} else if (eventUploadData.bizType == uint8(BizType.Settlement)) {
    EventTypes.Settlement memory settlement = abi.decode(eventUploadData.data, (EventTypes.Settlement));
    SettlementSignature memory settlementSignature = SettlementSignature({ /* campos del struct */ });
```

`abi.decode` de un tipo **dinámico** honra la primera palabra (la cabecera ABI = *offset* donde empieza el struct). Por tanto el hash del motor depende de **dónde apunta** esa palabra.

En cambio, la ejecución (`OperatorManagerImplB._processEventUpload`) **descarta** esa palabra y pega la cola tal cual:

```solidity
uint256 dataOffset = 0;
if (_isDynamicBizType(data.bizType)) { dataOffset = 32; }

require(data.data.length >= dataOffset, "Data too short");
bytes memory dataWithoutOffset = abi.encodePacked(data.data[dataOffset:]);
uint256 eventOffset = 64;   // 0x40 for eventOffset + eventId
bytes memory encodedCalldata = dataOffset == 0
    ? abi.encodePacked(selector, dataWithoutOffset, abi.encode(data.eventId))
    : abi.encodePacked(selector, abi.encode(eventOffset), abi.encode(data.eventId), dataWithoutOffset);
(bool success, bytes memory returnData) = address(ledger).call(encodedCalldata);
```

La calldata que llega al `Ledger` es `selector ‖ 0x40 ‖ eventId ‖ data.data[32:]`; el decoder del `Ledger` recalcula los offsets internos del struct tomando como base `data.data[32:]`, **no** `data.data[offset_declarado]`.

Consecuencia: la firma se calcula sobre `abi.decode(blob, (T))` y la ejecución sobre `abi.decode(blob[32:], (T))`. Solo coinciden si la cabecera vale exactamente `0x20`. **Un mismo blob puede significar dos cosas distintas.**

#### C.2.2 Payload de ataque

Sea `S` el evento benigno que el motor firmó y `E` el evento que el atacante quiere ejecutar. Con

```
blob = uint256(32 + |E_body|) ‖ E_body ‖ S_body        (E_body/S_body = abi.encode(X)[32:])
```

* el motor hace `abi.decode(blob, (T))` → lee el offset `32+|E_body|` → decodifica **`S`** (benigno) ⇒ **la firma valida**;
* el `Ledger` recibe `blob[32:]` = `E_body ‖ S_body` → decodifica **`E`** (del atacante) ⇒ **lo ejecuta**.

`|E_body|` es libre, así que el atacante elige la cabecera a voluntad. Afecta a **los 8 `bizType` dinámicos**: `1 Withdraw`, `2 Settlement`, `4 Liquidation`, `7 DelegateWithdraw`, `9 LiquidationV2`, `10 WithdrawSol`, `15 SettlementV3`, `17 LiquidationV3` (los que `_isDynamicBizType` marca con `dataOffset = 32`). Los estáticos no divergen (ambos decodificadores leen desde la posición 0), salvo por el desplazamiento del `eventId` descrito en C.2.6.

#### C.2.3 Prueba de concepto **ejecutada** (bytecode real en EVM)

Se replicaron los dos decodificadores exactamente como están en el repo (`signedView` = `abi.decode(blob,(T))`, `executedView` = el `abi.encodePacked` de `_processEventUpload`) y se desplegó en una EVM local (`py-evm`/`eth-tester`, solc 0.8.26):

```solidity
function signedView(bytes calldata blob) external pure returns (bytes32, int128) {
    Settlement memory s = abi.decode(blob, (Settlement));      // lo que firma el motor
    return (s.accountId, s.settledAmount);
}
function executedView(bytes calldata blob, uint64 eventId) external returns (bytes32, int128) {
    bytes memory cd = abi.encodePacked(
        LedgerStub.executeSettlement.selector,
        abi.encode(uint256(64)), abi.encode(eventId), blob[32:]  // lo que ejecuta el Ledger
    );
    (bool ok, bytes memory ret) = ledger.call(cd);
    require(ok, "ledger call failed");
    return abi.decode(ret, (bytes32, int128));
}
```

Payload generado: `S` = liquidación benigna de **1** unidad; `E` = `accountId = 0x9999…99`, `settledAmount = 1.000.000 USDC` (1e12 con 6 decimales). Salida real:

```
blob  : 800 bytes, head offset X = 416

  what the ENGINE signs / verifies      -> accountId 1111111111111111  settledAmount 1
  what the LEDGER executes (pre-fix)    -> accountId 9999999999999999  settledAmount 1000000000000
  SAME BLOB, DIFFERENT MEANING: True

  POST-FIX: malicious blob REJECTED     -> NonCanonicalDataOffset
  POST-FIX: canonical blob still works  -> 1111111111111111  1
```

El mismo `bytes` que el motor firma como un *settle* de 1 wei se ejecuta como un *settle* de 1.000.000 USDC a favor de una cuenta arbitraria. **No es una hipótesis de lectura de código: es bytecode ejecutado.**

#### C.2.4 Impacto: qué puede hacer quien tenga la clave del `operator`

`eventUpload` es `onlyOperator`, así que el atacante debe ser el operador (o quien reciba de CEFI el lote ya firmado para transmitirlo). Ese es exactamente el rol que la firma del motor debía **no** poder fabricar eventos: es la barrera de integridad del sistema. Con C‑02, esa barrera desaparece y el operador puede, sobre el **mismo lote firmado** que está transmitiendo:

1. **Acuñar saldo interno sin límite** — `bizType 2` (`executeSettlement`): `account.balances[asset] += settlementExecutions[i].settledAmount` para cada entrada, sin tope y **sin comprobar que el saldo quede ≥ 0** (la comprobación está comentada en `LedgerImplA.sol:273‑275`). La única validación es `totalSettleAmount == settlement.settledAmount`, y **ambos** los pone el atacante. Con `insuranceTransferAmount != 0` la misma llamada debita el **fondo de seguros** (`insuranceFund.subBalance`) y lo acredita a la cuenta del atacante.
2. **Retirar los USDC del `Vault` hasta agotarlo** — `bizType 1` (`executeWithdrawAction`): el struct ejecutado es un retiro de la cuenta del atacante (`accountId`, `sender`, `receiver`, `tokenAmount`, `withdrawNonce`), y `r,s,v` —que la firma del motor **no** cubre, porque los firma el usuario— los aporta el propio atacante, que es dueño de la cuenta. `vaultManager.getBalance` acota el pago al saldo real del Vault, es decir, el atacante extrae **todo el USDC de esa cadena**.
3. **Robar saldo de cualquier cuenta** — `bizType 4/9/17` (`executeLiquidation*`): mueve saldo desde la cuenta «liquidada» (elegida por el atacante) al fondo de seguros o a la cuenta que indique.

En otras palabras: **la firma del motor deja de ser un control de integridad para todos los eventos dinámicos.** Un operador comprometido (clave caliente, en línea, en cloud, rotada con frecuencia) pasa de «puede transmitir lo que el motor firmó» a «puede fabricar cualquier settle/retiro»: drenaje total del `Vault` y del fondo de seguros de cada cadena.

**Honestidad sobre la precondición:** C‑02 **no** es permissionless — requiere la clave `operator` (o control del componente que transmite el lote). Se clasifica **Crítico** igualmente porque (a) es el control de seguridad central del sistema el que se rompe, (b) el compromiso de una clave caliente de operador es un escenario de modelado obligatorio —y precisamente para eso existe la firma del motor— y (c) el impacto es pérdida total de fondos de todos los usuarios de la cadena, no degradación parcial.

#### C.2.5 Corrección aplicada (verificada)

Fijar la cabecera al valor canónico para los tipos dinámicos hace que ambos decodificadores lean el struct en la misma posición (misma base, misma longitud disponible: `blob.length‑32` en la firma vs. `calldatasize‑68 = L‑32` en la ejecución):

```solidity
// src/OperatorManagerImplB.sol — [AUDIT-FIX C-02]
require(data.data.length >= dataOffset, "Data too short");
if (dataOffset != 0) {
    require(abi.decode(data.data[:32], (uint256)) == 32, "NonCanonicalDataOffset");
}
```

* No cambia el esquema de firma ⇒ **no requiere cambios en CEFI** (el motor ya emite `abi.encode(struct)`, cuya cabecera es `0x20`).
* Coste: 3 líneas, +141 bytes de bytecode (`OperatorManagerImplB` 24.312 → **24.453**, quedan **123 bytes** de margen EIP‑170 con `runs=200`).
* Verificado en la PoC: el blob malicioso revierte con `NonCanonicalDataOffset` y el blob canónico sigue ejecutándose igual.
* Cubre también la ruta `zip`: `OperatorManagerZip` re‑codifica cada evento con `abi.encode(...)` (canónico) antes de llamar a `eventUpload`, así que no era explotable por esa vía, pero la comprobación es defensa en profundidad.
* **Recomendación a futuro (cambio de esquema, requiere CEFI):** añadir `keccak256(eventUploadData.data)` (o directamente el blob) al mensaje firmado — la firma debe cubrir *los bytes que se ejecutan*, no una reinterpretación de ellos.

#### C.2.6 Endurecimiento adicional (bajo): desplazamiento del `eventId` en tipos estáticos

Para los tipos estáticos la calldata es `selector ‖ data.data ‖ eventId`. Si el blob es más largo que el struct, el `eventId` se lee de una posición desplazada: el atacante puede elegir el `eventId` que se guarda en `account.lastEngineEventId`, aunque el resto del struct no cambia. Impacto bajo (marcador de orden/reconciliación), pero se corrige gratis exigiendo la longitud exacta por `bizType` en el mismo `if`.

#### C.2.7 Test de regresión

`test/security/CalldataMismatch.t.sol` (nuevo): demuestra (1) que ambos decodificadores divergen sobre el mismo blob, (2) que **la firma del motor valida sobre el payload forjado** (se firma con `vm.sign` replicando `eventsUploadEncodeHash`), (3) que con el parche revierte con `NonCanonicalDataOffset` y (4) que el payload canónico sigue ejecutándose. Compila con solc 0.8.26 + forge‑std v1.5.0 (0 errores).

---


### 4.3 H‑01 — `LedgerImplB`: `int128` sin extensión de signo al leer *transient storage*

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

### 4.4 H‑02 — `delegateSwap` da al binomio `swapOperator`/`swapSigner` control total de llamadas desde el Vault

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

### 4.5 H‑03 — `setAllowedSymbolByOperator` no exige firma CEFI si el llamante tiene el rol

**Severidad:** Alto (según política de roles)
**Ubicación:** `src/VaultManager.sol:189‑204`, `src/OperatorManager.sol:246‑281`

**Descripción.** El *permissionless listing* se diseñó con dos candados: (a) el `OperatorManager` verifica firma CEFI + `sequenceId` estrictamente incremental + `chainId == block.chainid`, y (b) `VaultManager.setAllowedSymbolByOperator` exige `onlyOwnerOrRole(SYMBOL_MANAGER_ROLE)`. Pero (b) es un control **independiente**: cualquier dirección con `SYMBOL_MANAGER_ROLE` en `VaultManager` puede listar/deslistar símbolos arbitrarios **sin** pasar por (a) ni por el `operator`. Si ese rol se concede a una EOA de operaciones, el candado CEFI es decorativo.

**Impacto.** Listado de símbolos no autorizados (mercados que el motor no controla) ⇒ el motor podría subir trades de un símbolo sin mercado de precios, con `marketManager` sin `perpMarketCfg` ⇒ cálculos con mark price 0. También permite deslistar símbolos de forma abrupta (`revert SymbolNotAllowed` en settlements/liquidaciones ⇒ bloqueo de operaciones).

**Recomendación.** Restringir `setAllowedSymbolByOperator` a `onlyOwner` o a `msg.sender == operatorManagerAddress` (nuevo `onlyOperatorManager` en `VaultManager`), y dejar el rol `SYMBOL_MANAGER_ROLE` únicamente para `setMaxWithdrawFee`/`disableDepositToken`. Documentar quién tiene el rol en producción y verificarlo on‑chain.

---

### 4.6 M‑01 — Allowance colgante en `withdraw2Contract` (parcheado)

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

### 4.7 M‑02 — La `fee` del retiro no está firmada por el usuario y el tope por defecto es “ilimitado”

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

### 4.8 M‑03 — `Vault.withdraw`: el mensaje cross‑chain se envía antes de pagar; si el pago falla, el usuario pierde el saldo

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

### 4.9 M‑04 — `rebalanceMint`: en el `catch` se acredita `data.amount` sin verificar lo acuñado

**Severidad:** Medio
**Ubicación:** `src/vaultSide/Vault.sol:690‑740` (original)

En el camino de éxito se mide el delta real (`balanceAfterMint - balanceBeforeMint`) y, para el modelo *normal*, se exige `== data.amount`. En el `catch` (solo `catch Error(string)`), si el motivo es exactamente `"Nonce already used"` se reporta `success = true` con **`amount: data.amount`** (valor del mensaje cross‑chain, no verificado). Idéntico problema si en el futuro CCTP cambia el texto del error o si el mensaje se recibió con un importe distinto (los fees del modelo *fast* se descuentan en el *burn*, no en el *mint*).

**Impacto.** Sobre‑acreditación de `tokenBalanceOnchain[mintChainId]` en el `VaultManager` ⇒ el `Ledger` permite retiros contra un saldo que no existe en el Vault ⇒ insolvencia parcial.

**Recomendación.** En el `catch` no acreditar cantidades: registrar el rebalanceo como `Fail` y dejar la reconciliación a un flujo administrativo explícito, o medir el delta real de balance en ambos caminos. Añadir también `catch (bytes memory)` para no dejar sin manejar los reverts con error personalizado.

---

### 4.10 M‑05 — `VaultManager`: el *ring buffer* de 100 rebalanceos puede sobrescribir un estado `Pending`

**Severidad:** Medio
**Ubicación:** `src/VaultManager.sol:44` (`MAX_REBALACE_SLOT = 100`), `:262`, `:271`, `:293`, `:310`

`rebalanceStatus[rebalanceId % 100]` se **sobrescribe** con cada nuevo `executeRebalanceBurn` sin comprobar si el slot pertenece a otro `rebalanceId` aún `Pending`. Si el rebalanceo `X` sigue pendiente (el mensaje cross‑chain aún no volvió) cuando llega `X+100`:

* el `burnFinish` de `X` revierte con `RebalanceIdNotMatch` para siempre;
* `tokenBurnFrozenBalanceOnchain` queda con el importe congelado permanentemente y `tokenBalanceOnchain` ya decrementado ⇒ **pérdida contable permanente** de esa cantidad (el Vault sigue teniendo los tokens, pero el `Ledger` los da por quemados).

**Recomendación.** Guardar el estado en un `mapping(uint64 => RebalanceStatus)` (coste de gas despreciable en una operación administrativa) o revertir si el slot está ocupado por otro `rebalanceId` distinto. Añadir además una función de reconciliación `onlyOwner` para cancelar un rebalanceo atascado.

---

### 4.11 L‑01 — `withdraw2Contract` no revierte para `vaultType` no soportado (parcheado)

**Severidad:** Bajo
**Ubicación:** `src/vaultSide/Vault.sol:563‑570` (original)
**Estado:** **corregido** (`[AUDIT-FIX L-01]`, nuevo error `UnsupportedVaultType` en `IVault`).

El `if / else if` no tenía rama `else`. Con `vaultType == VaultTypes.VaultEnum.UserVault (1)` no se pagaba nada, pero el mensaje cross‑chain ya se había enviado ⇒ mismo efecto que M‑03 (usuario debitado, fondos atrapados). Hoy el `Ledger` (`LedgerImplD._validateEvmReceiver`, `:242‑268`) bloquea ese caso con `revert NotImplemented()`; ahora el `Vault` también (defensa en profundidad).

---

### 4.12 L‑02 — `rebalanceBurn` deja allowance residual (parcheado)

**Severidad:** Bajo
**Ubicación:** `src/vaultSide/Vault.sol:663` (original)

`IERC20(burnToken).approve(tokenMessengerContract, data.amount)` seguido de un `try/catch` que **se traga** el fallo: si `depositForBurn` revierte, la allowance sobrevive. Hoy el spender es el `TokenMessenger` de Circle (de confianza), pero el patrón es frágil y además usa `approve` crudo (no `safeApprove`) ⇒ con tokens no estándar el retorno `false` se ignora silenciosamente.

**Corrección aplicada.** `approve(tokenMessengerContract, 0)` al final del flujo (éxito y fallo). Recomendado además: usar `SafeERC20.safeApprove`/`safeIncreaseAllowance` (OZ 4.8.2 no incluye `forceApprove`) y comprobar el `bool` de retorno de `approve` para tokens no estándar.

---

### 4.13 L‑03 — `DecompressorExtension.decompress()` público ejecuta `delegatecall` a sí mismo (parcheado)

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

### 4.14 L‑04 — `Vault` sin *storage gap* (parcheado)

**Severidad:** Bajo
**Ubicación:** `src/vaultSide/Vault.sol` (declaración de estado)

`Ledger` y `OperatorManager` reservan `uint256[36]` / `uint256[37]` de `__gap`, pero `Vault` —el contrato con más historial de upgrades y que custodia los fondos— no reservaba ninguno: la seguridad de cada upgrade depende de una disciplina *append‑only* estricta y de que nadie inserte una variable en medio (p. ej. junto a `tokenMessengerContract`).

**Corrección aplicada.** `uint256[42] private __gap;` al final del bloque de estado (no altera los slots existentes). Regla: las variables nuevas van **antes** del gap y se reduce su tamaño en consecuencia.

---

### 4.15 L‑05 — `bizType` no forma parte del mensaje firmado

**Severidad:** Bajo
**Ubicación:** `src/library/Signature.sol:414‑470` (`eventsUploadEncodeHash`), `src/OperatorManagerImplB.sol:44‑77`

`eventsUploadEncodeHash` clasifica cada evento por `bizType` y lo decodifica en una estructura tipada; el `bizType` en sí **no** se incluye en el payload firmado. `bizType == 1` (Withdraw → `executeWithdrawAction`, verifica firma ECDSA del usuario) y `bizType == 7` (DelegateWithdraw → `executeDelegateWithdrawAction`, verifica la firma del *delegate signer*) producen **exactamente el mismo** `WithdrawDataSignature` y caen en el mismo array. Por tanto una carga firmada para `bizType 1` puede reenviarse como `bizType 7` (y viceversa) y ejecutar la otra ruta.

> **Nota de re‑graduación:** este hallazgo es el caso *menor* del mismo defecto de fondo que C‑02 —la firma cubre una **reinterpretación** del blob y no los bytes que se ejecutan—. El parche de C‑02 no lo cierra: sigue siendo recomendable incluir `bizType` (y `keccak256(data.data)`) en el mensaje firmado.

**Impacto.** Requiere que el atacante controle el *relayer*/*operator* que envía el `eventUpload` (o que intercepte la carga antes de su inclusión). El daño se limita a que la ruta alternativa aplica sus propias comprobaciones (la mayoría terminan en `state != 0` ⇒ evento de fallo sin mover fondos), pero rompe la garantía de que un evento firmado para una operación se ejecute como esa operación.

**Recomendación.** Incluir `bizType` en el *struct* firmado (`abi.encode(bizType, …)`) y/o decodificar siempre `data` a la estructura estricta del `bizType` declarado y comparar el re‑encode.

---

### 4.16 L‑06 — `delegateSwapWithExpiration`: la expiración la elige el llamante

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

### 4.17 L‑07 — Listado permissionless: secuencia estricta y no‑ops que revierten

**Severidad:** Bajo
**Ubicación:** `src/OperatorManager.sol:246‑281`, `src/VaultManager.sol:189‑204`

* `_sequenceId` debe ser **exactamente** `permissionlessListingSequenceId + 1`: un hueco (p. ej. CEFI emite 5 y on‑chain está en 3) bloquea la función hasta que se envíe el 4, que quizá nunca se firmó ⇒ **bloqueo permanente** del listado permissionless.
* `VaultManager.setAllowedSymbolByOperator` revierte con `EnumerableSetError` si la operación es un no‑op (añadir algo ya añadido o quitar algo ya quitado) ⇒ un reintento idempotente desde CEFI revierte siempre.

**Recomendación.** Aceptar `_sequenceId >= expected` (con emisión del salto) y tratar los no‑ops como éxito (`succ == false` ⇒ `emit` y `return`), o exponer un `onlyOwner` de recuperación para fijar `permissionlessListingSequenceId`.

---

### 4.18 Informativos

* **I‑01 `SwapSignature.sol` es código muerto e inconsistente.** No se usa en ningún sitio (verificado con `grep`). Su `DELEGATE_SWAP_TYPEHASH` declara `uint256 swapNonce` pero codifica `data.tradeId`. Si alguien lo conectara por error, el digest no sería interoperable. **Eliminarlo** o corregirlo.
* **I‑02 Firmas EIP‑191.** Los *uploads* del motor y las firmas de swap usan `toEthSignedMessageHash` (prefijo `"\x19Ethereum Signed Message"`) en vez de EIP‑712. Funciona, pero impide que el firmante vea campos estructurados en su *wallet* (riesgo de *phishing* de firmas) y no incluye `chainId`/`verifyingContract` en el caso de `perpUpload`/`eventsUpload` (protección sólo por `batchId` monotónico).
* **I‑03 Margen EIP‑170.** Con la configuración oficial (`runs = 200`): `OperatorManagerImplB` = **24.453 bytes** tras el parche de C‑02 (límite 24.576 ⇒ **123 bytes de margen**), `LedgerImplA` = 23.449, `LedgerImplC` = 23.176, `Vault` = 21.841 (`runs=1000`: 24.727 / 24.367 / 24.123 / 23.652; `OperatorManagerImplB` **excede** el límite en esa configuración, como ya lo hacía antes del parche con 24.579). Cualquier añadido a `OperatorManagerImplB` puede hacerlo no desplegable. Verificar el `runs` usado en el despliegue real.
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
* **Pero** la firma del motor del `eventUpload` **no** cubre el blob ejecutado sino su decodificación: ver C‑02 (crítico). Es el único punto donde el principio “firmar exactamente lo que se ejecuta” se rompe, y era suficiente para anular todo el modelo.

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
src/OperatorManagerImplB.sol        | pin de la cabecera ABI (== 0x20) en _processEventUpload [C-02]
test/security/CalldataMismatch.t.sol| test de regresión de C-02 (nuevo, 4 casos)              [C-02]
```

**Verificación:** compilación completa de `src/` con `solc 0.8.26` (`evmVersion: cancun`), `runs = 1000` y `runs = 200` ⇒ **0 errores**. Tamaños con `runs = 200` (configuración oficial): antes → después
`Vault` 21.475 → **21.841** (+366), `OperatorManagerZip` 12.471 → **12.516** (+45), `LedgerImplB` 6.319 (sin cambio), `OperatorManagerImplB` 24.312 → **24.453** (+141 por el parche de C‑02). Todos por debajo de 24.576, pero **`OperatorManagerImplB` queda con solo 123 bytes de margen**: ver I‑03.

**No se modificó** nada relacionado con: formatos de firma, orden de las llamadas cross‑chain, `maxWithdrawFee`, `bizType`, `rebalanceMint`, el *ring buffer* de rebalanceos ni los roles; todos esos cambios exigen coordinación off‑chain y se documentan como recomendación.

---

## 7. Riesgo residual y checklist de despliegue

1. **Roles:** verificar on‑chain que `owner()` de cada proxy es un multisig, que `operatorAddress`/`zipOperatorAddress`/`swapOperator` son EOAs dedicadas (no compartidas con otras funciones) y que `SYMBOL_MANAGER_ROLE`/`BROKER_MANAGER_ROLE` no estén en EOAs de operaciones.
2. **Timelock:** `ProxyAdmin.owner()` y `owner()` de `Vault`/`Ledger` con retardo ≥ 48 h para upgrades y cambios de `crossChainManager`.
3. **`maxWithdrawFee`:** fijar un tope explícito por token en cada cadena (hoy `0` = ilimitado).
4. **`OperatorManager.setOperatorManagerZipAddress`:** si no se usa el `zip`, dejarlo en `address(0)`; si se usa, el contrato `OperatorManagerZip` debe tener su `zipOperatorAddress` dedicado.
5. **No habilitar** `executeProcessValidatedFuturesBatch` hasta que exista el test diferencial de la sección 4.3.
6. **Monitorización on‑chain:** alertas sobre `ChangeCrossChainManager`, `ChangeOperator`, `ChangeLedgerImpl*`, `PrimeWalletSet`, `VaultSet`, `SetAllowedSymbol`, `WithdrawFailed`, `CalAverageEntryPriceSkipped` y `RebalanceBurnResult`.
7. **`forge test`** completo (con `--profile ci`, `fuzz_runs = 100_000`) sobre esta rama antes de cualquier despliegue; el entorno de auditoría no disponía de Foundry.
8. **Clave `operator` (C‑02):** el parche la deja sin capacidad de fabricar eventos, pero el rol sigue siendo caliente y con capacidad de *griefing*. Custodiarla en HSM/KMS, rotación periódica, y **verificar on‑chain** que `operatorAddress` es una EOA dedicada. Añadir un *watchdog* que compare el `EventUpload` emitido off‑chain con el ejecutado on‑chain (`eventId`, `bizType`, hash del blob).
9. **Cabecera ABI canónica (C‑02):** el motor ya emite `abi.encode(struct)` (cabecera `0x20`); confirmar en la integración que CEFI **nunca** genera los blobs con otro formato. Si lo hiciera, el parche los rechazaría con `NonCanonicalDataOffset` (fail‑closed, no fail‑open).

---

## 8. Tests de regresión recomendados

| Hallazgo | Test |
|---|---|
| **C‑02** | **`test/security/CalldataMismatch.t.sol` (ya escrito):** (1) divergencia de decodificadores sobre el mismo blob, (2) la firma del motor valida sobre el payload forjado, (3) el parche revierte con `NonCanonicalDataOffset`, (4) el payload canónico sigue ejecutándose. Añadir un *fuzz* que genere blobs con cabeceras arbitrarias y exija `revert` salvo cabecera `0x20`. |
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

El código está **bien estructurado para un sistema de este tamaño**: separación de responsabilidades por `delegatecall` (con layouts de almacenamiento consistentes), doble verificación (rol + firma criptográfica) en las rutas que mueven valor, aritmética con *checked math* y librerías de casteo seguro, y snapshots de estado (`escrowBalances`) para las transferencias internas asíncronas.

**Pero sí existe una vulnerabilidad crítica (C‑02)**, y no es una hipótesis: es una divergencia entre lo que el motor firma y lo que la cadena ejecuta, demostrada con bytecode real en una PoC ejecutada. El sistema tiene una propiedad implícita —«la firma del motor autoriza exactamente el evento que se ejecuta»— que **no se cumple**: `Signature.eventsUploadEncodeHash` decodifica con `abi.decode` (honrando la cabecera ABI) y `_processEventUpload` re‑ensambla la calldata descartándola. Un blob de 800 bytes es, a la vez, un settle de 1 wei (para el firmante) y un settle de 1.000.000 USDC (para el `Ledger`). Afecta a los 8 `bizType` dinámicos y, con la clave `operator`, permite acuñar saldo, vaciar el seguro y drenar el `Vault`.

Riesgos reales, en orden de impacto:

1. **C‑02 (crítico, parcheado aquí):** rompe el control de integridad central. Sin el parche, un operador comprometido drena la cadena. Con el parche, firma y ejecución decodifican el mismo struct. **Pendiente:** ejecutar el test de regresión en CI y, a medio plazo, cambiar el esquema para firmar `keccak256(data.data)` (los bytes crudos), que es la única forma de que el defecto no pueda reaparecer con un cambio de codificación.
2. **Centralización (C‑01):** una sola clave `owner` puede vaciar el `Vault` de su cadena. No se resuelve con código en este repo: requiere multisig + timelock + límites. **“0 riesgos” no es una afirmación honesta mientras esto no se mitigue operativamente.**
3. **Camino latente roto (H‑01):** corregido y verificado; no debe habilitarse el *batch upload* sin el test diferencial.
4. **Confianza en el motor/usuario (M‑02, L‑05):** la firma del usuario no cubre la comisión y el `bizType` no está autenticado; requieren cambios coordinados con CEFI.
5. **Manejo de fallos de pago (M‑03, L‑01) y de rebalanceo (M‑04, M‑05):** degradan la contabilidad en escenarios concretos; todos tienen mitigación clara y acotada.

**Sobre “0 riesgos”:** no es alcanzable, y este informe es la prueba. La auditoría anterior a esta revisión concluía «no hay ningún crítico permissionless»; eso era cierto y aun así el crítico existía — porque el vector no era permissionless, sino que atravesaba el límite de confianza que la propia firma del motor definía. Los parches aplicados (`[AUDIT-FIX …]`) son quirúrgicos, compilan y no cambian la semántica de los flujos válidos; el de C‑02 es de 3 líneas y **no requiere cambios off‑chain**.

**Anexo 10** documenta el barrido exhaustivo de control de acceso (187 funciones externas, 40 sin guard, 36 de ellas `view`) y concluye que **no hay ningún crítico permissionless en `src/`**: la superficie permissionless real (`lzReceive`/`receiveMessage` del `VaultCrossChainManager` y del `LedgerCrossChainManager`) **no está en este repositorio**, y el `Vault` paga ciegamente lo que esa capa le pide.

---

## 10. Anexo — Barrido exhaustivo de control de acceso: ¿existe un crítico *permissionless*?

**Pregunta:** ¿hay alguna ruta por la que un tercero **sin ningún rol** (ni `owner`, ni `operator`, ni `crossChainManager`, ni `ledger`, ni rol de `AccessControl`) pueda mover valor o corromper estado?

**Método (ejecutado, no estimado).** Se enumeraron *todas* las funciones `external`/`public` de los 7 contratos de entrada (`Vault`, `VaultManager`, `Ledger`, `OperatorManager`, `OperatorManagerZip`, `FeeManager`, `MarketManager`) y se extrajo el guard de cada una (modificador o `require` en el cuerpo). Se verificó además:

* **No existe `fallback()` ni `receive()` en ningún contrato de `src/`** (`grep -rn "fallback\|receive()" src/` ⇒ 0 resultados). Consecuencia: los contratos "impl" (`OperatorManagerImplA/B`, `LedgerImplA/B/C/D`, `LedgerImplView`) **solo** son alcanzables por `delegatecall` desde su proxy, y toda función del proxy tiene su guard. Los `Impl*` desplegados sueltos escriben en su propio almacenamiento (vacío), tienen `_disableInitializers()` y `ledger`/`vaultManager` en `address(0)` ⇒ inertes.
* Cada `initialize()` está protegido por `initializer` y los proxies se despliegan con `abi.encodeWithSignature("initialize()")` **en el constructor** (`script/vault/DeployProxyVault.s.sol:26`), es decir, sin ventana de front-running.

**Resultado.**

| Contrato | `external`/`public` | Sin guard | De las cuales `view`/`pure` | Efectivamente invocables por un tercero |
|---|---|---|---|---|
| `Vault` | 43 | 11 | 9 | `deposit`, `depositTo` (intencionadas) · `delegateSigner` (solo emite evento) · `attemptTransferNative` (autoguardada: `msg.sender == address(this)`) |
| `VaultManager` | 34 | 12 | 12 | — |
| `Ledger` | 60 | 11 | 11 | — |
| `OperatorManager` | 27 | 2 | 2 | — |
| `OperatorManagerZip` | 10 | 2 | 0 | `placeholder`, `placeholder2` (cuerpos vacíos) |
| `FeeManager` | 6 | 1 | 1 | — |
| `MarketManager` | 7 | 1 | 1 | — |
| **Total** | **187** | **40** | **36** | **4 (+2 no-ops)** |

Las 4 funciones permissionless con efecto se revisaron línea por línea:

* **`deposit` / `depositTo`** — `checkDepositToken` exige `allowedTokenSet.contains(hash)` **y** `allowedToken[hash] != address(0)` (no basta con un hash inventado: `safeTransferFrom` a una dirección sin código devolvería `true` y permitiría acuñar saldo contra un token inexistente — **está cerrado**); `accountId` se ata a `keccak(receiver, brokerHash)` salvo para `vaultAdapter`; `tokenAmount > 0`; límite de depósito; `safeTransferFrom` antes del mensaje cross-chain. No permite acreditar a una cuenta ajena ni acreditar sin pagar.
* **`delegateSigner`** — exige `msg.sender.code.length != 0`, `delegateSigner` sin código y `brokerHash` permitido; **solo emite un evento**, no escribe estado.
* **`attemptTransferNative`** — `require(msg.sender == address(this))`.
* **`placeholder` / `placeholder2`** — cuerpos vacíos (existen solo para generar el ABI de los structs de `zip`).

**Conclusión.** **No existe un crítico permissionless en `src/`.** Es un resultado negativo *demostrado por enumeración*, no una impresión: la única función permissionless que mueve valor es `deposit`, y su validación es sólida.

**Dónde está, entonces, la superficie permissionless de verdad:** **fuera de este repositorio.** `Vault.withdraw`, `Vault.withdraw2Contract`, `Vault.rebalanceBurn/Mint`, `Vault.setBrokerFromLedger` y `Ledger.accountDeposit` son **ejecutores ciegos** de `crossChainManagerAddress`:

```solidity
// Vault.sol:483
function withdraw(VaultTypes.VaultWithdraw calldata data) public onlyCrossChainManager whenNotPaused {
    IVaultCrossChainManager(crossChainManagerAddress).withdraw(data);   // mensaje saliente
    uint128 amount = data.tokenAmount - data.fee;
    tokenAddress.safeTransfer(data.receiver, amount);                   // pago, sin contabilidad propia
```

El `Vault` paga lo que el CCM le pida (`solo` comprueba `balanceOf(this) >= amount`). Ese CCM (`VaultCrossChainManager` / `LedgerCrossChainManager`, con sus `lzReceive`/`receiveMessage`/`receiveMessageV2`) **no está en `src/`** ni en `config/`: solo hay interfaces (`IVaultCrossChainManager.sol`, `ILedgerCrossChainManager.sol`) y un mock de test. **Si existe un drenaje permissionless en este sistema, está ahí** — en la verificación del `peer`/`srcEid`, la autenticación del endpoint y la anti-repetición de esa capa — y no puede auditarse desde este repositorio.

**Recomendación:** aportar el repositorio/verificación del `VaultCrossChainManager` y del `LedgerCrossChainManager` para auditarlos; son, junto con `OperatorManager`, las tres piezas que sostienen todo el modelo de confianza, y las dos primeras son las únicas con entrada permissionless real.
