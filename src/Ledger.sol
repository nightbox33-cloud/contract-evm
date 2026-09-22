// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import "openzeppelin-contracts-upgradeable/contracts/access/OwnableUpgradeable.sol";
import "./dataLayout/LedgerDataLayout.sol";
import "./interface/ILedger.sol";
import "./interface/IVaultManager.sol";
import "./interface/ILedgerCrossChainManager.sol";
import "./interface/IMarketManager.sol";
import "./interface/IFeeManager.sol";
import "./interface/ILedgerCrossChainManagerV2.sol";

import "./oz5Revised/AccessControlRevised.sol";

/// @title Ledger contract
/// @author Orderly_Rubick
/// @notice Ledger is responsible for saving traders' Account (balance, perpPosition, and other meta)
/// and global state (e.g. futuresUploadBatchId)
/// This contract should only have one in main-chain (e.g. OP orderly L2)
contract Ledger is ILedger, OwnableUpgradeable, LedgerDataLayout, AccessControlRevised {
    // Using Storage as OZ 5.0 does
    struct LedgerStorage {
        // Because of EIP170 size limit, the implementation should be split to impl contracts
        address ledgerImplA;
        address ledgerImplB;
        address ledgerImplC;
        address ledgerImplD;
        address ledgerImplView;
    }

    // keccak256(abi.encode(uint256(keccak256("orderly.Ledger")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LedgerStorageLocation = 0x220427b0bfdd3e8fe9a4c85265eee2c38bb3f4591655846e819d36b613b63200;

    /* ================ Role ================ */
    // bytes32 public constant SYMBOL_MANAGER_ROLE = keccak256("ORDERLY_MANAGER_SYMBOL_MANAGER_ROLE");
    bytes32 public constant BROKER_MANAGER_ROLE = keccak256("ORDERLY_MANAGER_BROKER_MANAGER_ROLE");

    function _getLedgerStorage() private pure returns (LedgerStorage storage $) {
        assembly {
            $.slot := LedgerStorageLocation
        }
    }

    /// @notice check if the caller is the owner or has the role
    modifier onlyOwnerOrRole(bytes32 role) {
        if (!hasRole(role, msg.sender) && msg.sender != owner()) {
            revert AccessControlUnauthorizedAccount(msg.sender, role);
        }
        _;
    }

    /// @notice require operatorManager
    modifier onlyOperatorManager() {
        if (msg.sender != operatorManagerAddress) revert OnlyOperatorCanCall();
        _;
    }

    /// @notice require crossChainManager
    modifier onlyCrossChainManager() {
        if (msg.sender != crossChainManagerAddress) revert OnlyCrossChainManagerCanCall();
        _;
    }

    /// @notice require crossChainManagerV2
    modifier onlyCrossChainManagerV2() {
        if (msg.sender != crossChainManagerV2Address) revert OnlyCrossChainManagerV2CanCall();
        _;
    }

    /// @notice check non-zero address
    modifier nonZeroAddress(address _address) {
        if (_address == address(0)) revert AddressZero();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize() external override initializer {
        __Ownable_init();
    }

    /// @notice Set the address of ledgerImplA contract
    function setLedgerImplA(address _ledgerImplA) external override onlyOwner nonZeroAddress(_ledgerImplA) {
        emit ChangeLedgerImplA(_getLedgerStorage().ledgerImplA, _ledgerImplA);
        _getLedgerStorage().ledgerImplA = _ledgerImplA;
    }

    /// @notice Set the address of ledgerImplB contract
    function setLedgerImplB(address _ledgerImplB) external override onlyOwner nonZeroAddress(_ledgerImplB) {
        emit ChangeLedgerImplB(_getLedgerStorage().ledgerImplB, _ledgerImplB);
        _getLedgerStorage().ledgerImplB = _ledgerImplB;
    }

    /// @notice Set the address of ledgerImplC contract
    function setLedgerImplC(address _ledgerImplC) external override onlyOwner nonZeroAddress(_ledgerImplC) {
        emit ChangeLedgerImplC(_getLedgerStorage().ledgerImplC, _ledgerImplC);
        _getLedgerStorage().ledgerImplC = _ledgerImplC;
    }

    /// @notice Set the address of ledgerImplD contract
    function setLedgerImplD(address _ledgerImplD) external override onlyOwner nonZeroAddress(_ledgerImplD) {
        emit ChangeLedgerImplD(_getLedgerStorage().ledgerImplD, _ledgerImplD);
        _getLedgerStorage().ledgerImplD = _ledgerImplD;
    }

    /// @notice Set the address of ledgerImplView contract
    function setLedgerImplView(address _ledgerImplView) external override onlyOwner nonZeroAddress(_ledgerImplView) {
        emit ChangeLedgerImplView(_getLedgerStorage().ledgerImplView, _ledgerImplView);
        _getLedgerStorage().ledgerImplView = _ledgerImplView;
    }

    /// @notice Set the address of operatorManager contract
    /// @param _operatorManagerAddress new operatorManagerAddress
    function setOperatorManagerAddress(address _operatorManagerAddress)
        external
        override
        onlyOwner
        nonZeroAddress(_operatorManagerAddress)
    {
        emit ChangeOperatorManager(operatorManagerAddress, _operatorManagerAddress);
        operatorManagerAddress = _operatorManagerAddress;
    }

    /// @notice Set the address of crossChainManager on Ledger side
    /// @param _crossChainManagerAddress  new crossChainManagerAddress
    function setCrossChainManager(address _crossChainManagerAddress)
        external
        override
        onlyOwner
        nonZeroAddress(_crossChainManagerAddress)
    {
        emit ChangeCrossChainManager(crossChainManagerAddress, _crossChainManagerAddress);
        crossChainManagerAddress = _crossChainManagerAddress;
    }

    /// @notice Set the address of crossChainManagerV2 on Ledger side
    /// @param _crossChainManagerV2Address  new crossChainManagerV2Address
    function setCrossChainManagerV2(address _crossChainManagerV2Address)
        external
        override
        onlyOwner
        nonZeroAddress(_crossChainManagerV2Address)
    {
        emit ChangeCrossChainManagerV2(crossChainManagerV2Address, _crossChainManagerV2Address);
        crossChainManagerV2Address = _crossChainManagerV2Address;
    }

    /// @notice Set the address of vaultManager contract
    /// @param _vaultManagerAddress new vaultManagerAddress
    function setVaultManager(address _vaultManagerAddress)
        external
        override
        onlyOwner
        nonZeroAddress(_vaultManagerAddress)
    {
        emit ChangeVaultManager(address(vaultManager), _vaultManagerAddress);
        vaultManager = IVaultManager(_vaultManagerAddress);
    }

    /// @notice Set the address of marketManager contract
    /// @param _marketManagerAddress new marketManagerAddress
    function setMarketManager(address _marketManagerAddress)
        external
        override
        onlyOwner
        nonZeroAddress(_marketManagerAddress)
    {
        emit ChangeMarketManager(address(marketManager), _marketManagerAddress);
        marketManager = IMarketManager(_marketManagerAddress);
    }

    /// @notice Set the address of feeManager contract
    /// @param _feeManagerAddress new feeManagerAddress
    function setFeeManager(address _feeManagerAddress) external override onlyOwner nonZeroAddress(_feeManagerAddress) {
        emit ChangeFeeManager(address(feeManager), _feeManagerAddress);
        feeManager = IFeeManager(_feeManagerAddress);
    }

    /// @notice Set the address of prime wallet for a given accountId
    /// @param id accountId or spId
    /// @param _primeWallet address of the prime wallet
    function setPrimeWallet(bytes32 id, address _primeWallet) external onlyOwner nonZeroAddress(_primeWallet) {
        idToPrimeWallet[id] = _primeWallet;
        emit PrimeWalletSet(id, _primeWallet);
    }

    /// @notice Set the address of prime wallet on Solana for a given accountId
    /// @param _id accountId or spId
    /// @param _solanaPrimeWallet address of the prime wallet
    function setSolanaPrimeWallet(bytes32 _id, bytes32 _solanaPrimeWallet) external onlyOwner {
        if (_solanaPrimeWallet == bytes32(0)) revert AddressZero();
        idToSolanaPrimeWallet[_id] = _solanaPrimeWallet;
        emit SolanaPrimeWalletSet(_id, _solanaPrimeWallet);
    }

     function setValidVault(address vault, bool isValid) external onlyOwner {
        isValidVault[vault] = isValid;
        emit VaultSet(vault, isValid);
    }

    /// @notice Add or remove an account from the average entry price recomputation skip list.
    /// @dev For accounts in this list, if the average entry price / opening cost
    ///      recomputation during perp trade upload would produce an out-of-range
    ///      value, the recomputation is skipped (position quantity and cost are
    ///      still updated) and a `CalAverageEntryPriceSkipped` event is emitted,
    ///      rather than reverting the upload. Owner-gated.
    /// @param accountId the account to configure
    /// @param allowed true to enable skipping for this account, false to use the standard behaviour
    function setCalAvgSkipAccount(bytes32 accountId, bool allowed) external onlyOwner {
        calAvgSkipList[accountId] = allowed;
        emit CalAvgSkipAccountSet(accountId, allowed);
    }

    /// @notice Get the amount of a token frozen balance for a given account and the corresponding withdrawNonce
    /// @param accountId accountId to query
    /// @param withdrawNonce withdrawNonce to query
    /// @param tokenHash tokenHash to query
    /// @return uint128 frozen value
    function getFrozenWithdrawNonce(bytes32 accountId, uint64 withdrawNonce, bytes32 tokenHash)
        external
        override
        returns (uint128)
    {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (uint128));
    }

    function batchGetUserLedger(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        public
        override
        returns (AccountTypes.AccountSnapshot[] memory accountSnapshots)
    {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (AccountTypes.AccountSnapshot[]));
    }

    function batchGetUserLedger(bytes32[] calldata accountIds)
        external
        returns (AccountTypes.AccountSnapshot[] memory)
    {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (AccountTypes.AccountSnapshot[]));
    }

    function getUserTokenBalance(bytes32 accountId, bytes32 tokenHash) external override returns (int128) {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (int128));
    }

    function batchGetUserLedgerV3(bytes32[] calldata accountIds, bytes32[] memory tokens, bytes32[] memory symbols)
        public
        override
        returns (AccountTypes.AccountSnapshotV3[] memory accountSnapshots)
    {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (AccountTypes.AccountSnapshotV3[]));
    }

    function batchGetUserLedgerV3(bytes32[] calldata accountIds)
        public
        override
        returns (AccountTypes.AccountSnapshotV3[] memory accountSnapshots)
    {   
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (AccountTypes.AccountSnapshotV3[]));
    }

    function batchGetUserBalance(bytes32[] calldata accountIds)
        external
        override
        returns (AccountTypes.AccountBalanceSnapshot[] memory)
    {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (AccountTypes.AccountBalanceSnapshot[]));
    }

    function getUserEscrowBalance(bytes32 accountId, bytes32 tokenHash) external override returns (uint128) {
        return escrowBalances[accountId][tokenHash];
    }

    function getUserTotalFrozenBalance(bytes32 accountId, bytes32 tokenHash) external  override returns (uint128) {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (uint128));
    }

    function getBalanceTransferState(uint256 transferId)
        external
        override
        returns (EventTypes.InternalTransferTrack memory)
    {
        bytes memory result = _delegatecall(
            _getLedgerStorage().ledgerImplView
        );
        return abi.decode(result, (EventTypes.InternalTransferTrack));
    }

    function getLedgerImpl() external view returns (address, address, address, address, address) {
        LedgerStorage storage $ = _getLedgerStorage();
        return ($.ledgerImplA, $.ledgerImplB, $.ledgerImplC, $.ledgerImplD, $.ledgerImplView);
    }

    /// Interface implementation

    /// @notice The cross chain manager will call this function to notify the deposit event to the Ledger contract
    function accountDeposit(AccountTypes.AccountDeposit calldata data) external override onlyCrossChainManager {
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function accountDepositSol(AccountTypes.AccountDepositSol calldata data) external override onlyCrossChainManagerV2 {
        _delegatecall(
            _getLedgerStorage().ledgerImplC
        );
    }

    function executeProcessValidatedFuturesV3(PerpTypes.FuturesTradeUploadV3 calldata trade)
        external
        override
        onlyOperatorManager
    {   
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeProcessValidatedFuturesV4(PerpTypes.FuturesTradeUploadV4 calldata trade)
        external
        override
        onlyOperatorManager
    {
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeProcessValidatedFutures(PerpTypes.FuturesTradeUpload calldata trade)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeProcessValidatedFuturesBatch(PerpTypes.FuturesTradeUpload[] calldata trades)
        external
        override
        onlyOperatorManager
    {   
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplB
        );
    }

    function executeWithdrawAction(EventTypes.WithdrawData calldata withdraw, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeWithdrawSolAction(EventTypes.WithdrawDataSol calldata withdraw, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplC
        );
    }

    function accountWithdrawFail(AccountTypes.AccountWithdraw memory withdraw) external override onlyOwner {
        _delegatecall(
           _getLedgerStorage().ledgerImplA
        );
    }

    function accountWithDrawFinish(AccountTypes.AccountWithdraw calldata withdraw)
        external
        override
        onlyCrossChainManager
    {
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeSettlement(EventTypes.Settlement calldata settlement, uint64 eventId)
        external
        override
        onlyOperatorManager
    {   
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeLiquidation(EventTypes.Liquidation calldata liquidation, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeLiquidationV2(EventTypes.LiquidationV2 calldata liquidation, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeAdl(EventTypes.Adl calldata adl, uint64 eventId) external override onlyOperatorManager { 
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeAdlV2(EventTypes.AdlV2 calldata adl, uint64 eventId) external override onlyOperatorManager { 
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeFeeDistribution(EventTypes.FeeDistribution calldata feeDistribution, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeDelegateSigner(EventTypes.DelegateSigner calldata delegateSigner, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeDelegateWithdrawAction(EventTypes.WithdrawData calldata delegateWithdraw, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplA
        );
    }

    function executeRebalanceBurn(RebalanceTypes.RebalanceBurnUploadData calldata data)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();        
        (uint32 dstDomain, address dstVaultAddress) = vaultManager.executeRebalanceBurn(data);
        // send cc message with:
        // rebalanceId, amount, tokenHash, burnChainId, mintChainId | dstDomain, dstVaultAddress
        ILedgerCrossChainManager(crossChainManagerAddress)
            .burn(
                RebalanceTypes.RebalanceBurnCCData({
                    dstDomain: dstDomain,
                    rebalanceId: data.rebalanceId,
                    amount: data.amount,
                    tokenHash: data.tokenHash,
                    burnChainId: data.burnChainId,
                    mintChainId: data.mintChainId,
                    dstVaultAddress: dstVaultAddress
                })
            );
    }

    function rebalanceBurnFinish(RebalanceTypes.RebalanceBurnCCFinishData calldata data)
        external
        override
        onlyCrossChainManager
    {
        vaultManager.rebalanceBurnFinish(data);
    }

    function executeRebalanceMint(RebalanceTypes.RebalanceMintUploadData calldata data)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        vaultManager.executeRebalanceMint(data);
        // send cc Message with:
        // rebalanceId, amount, tokenHash, burnChainId, mintChainId | messageBytes, messageSignature
        ILedgerCrossChainManager(crossChainManagerAddress)
            .mint(
                RebalanceTypes.RebalanceMintCCData({
                    rebalanceId: data.rebalanceId,
                    amount: data.amount,
                    tokenHash: data.tokenHash,
                    burnChainId: data.burnChainId,
                    mintChainId: data.mintChainId,
                    messageBytes: data.messageBytes,
                    messageSignature: data.messageSignature
                })
            );
    }

    function rebalanceMintFinish(RebalanceTypes.RebalanceMintCCFinishData calldata data)
        external
        override
        onlyCrossChainManager
    {
        vaultManager.rebalanceMintFinish(data);
    }

    function executeWithdraw2Contract(EventTypes.Withdraw2Contract calldata data, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeBalanceTransfer(EventTypes.BalanceTransfer calldata balanceTransfer, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplC
        );
    }

    function executeSwapResultUpload(EventTypes.SwapResult calldata swapResultUpload, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeWithdraw2ContractV2(EventTypes.Withdraw2ContractV2 calldata withdraw2ContractV2, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeSettlementV3(EventTypes.SettlementV3 calldata isoSettlement, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeAdlV3(EventTypes.AdlV3 calldata isoAdl, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeLiquidationV3(EventTypes.LiquidationV3 calldata liquidationV3, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    function executeMarginTransferV3(EventTypes.MarginTransferV3 calldata isoMarginTransfer, uint64 eventId)
        external
        override
        onlyOperatorManager
    {
        // _onlyOperatorManager();
        _delegatecall(
            _getLedgerStorage().ledgerImplD
        );
    }

    /// @notice Initiates cross-chain broker status modification to multiple vault chains
    /// @dev Only callable by owner, triggers cross-contract calls to VaultManager and LedgerCrossChainManager
    /// @param chainIds Array of destination chain IDs where broker status should be modified
    /// @param brokerHash Hash of the broker to be modified
    /// @param allowed true to add broker, false to remove broker 
    /// @param setBrokerIndex true to set broker index, false otherwise
    /// @param brokerIndex Index number to assign to the broker if setBrokerIndex is true
    function setBrokerFromLedger(
        uint256[] calldata chainIds, 
        bytes32 brokerHash, 
        bool allowed,
        bool setBrokerIndex,
        uint16 brokerIndex
    ) external override onlyOwnerOrRole(BROKER_MANAGER_ROLE) {
        // Validate input parameters
        require(chainIds.length > 0, "Ledger: empty chainIds");
        
        // Step 1: Update local VaultManager state for the broker
        // This updates the broker status in the local Ledger chain
        vaultManager.setBrokerFromLedger(brokerHash, allowed);
        
        // Step 2: Trigger cross-chain messages
        // Call LedgerCrossChainManager to send messages to vault chains
        ILedgerCrossChainManager(crossChainManagerAddress).setBrokerCrossChain(
            chainIds, 
            brokerHash, 
            allowed
        );

        // Step 3: Set broker hash and its index number if this broker should be supported on Solana chain
        if (allowed && setBrokerIndex) {
            ILedgerCrossChainManagerV2(crossChainManagerV2Address).setBrokerFromLedger(msg.sender, brokerHash, brokerIndex);
        }

        
        emit SetBrokerFromLedgerInitiated(chainIds, brokerHash, allowed);
    }

    /* ================ Override AccessControlRevised To Simplify Access Control ================ */

    /// @notice Override grantRole
    function grantRole(bytes32 role, address account) public override onlyOwner {
        _grantRole(role, account);
    }

    /// @notice Override revokeRole
    function revokeRole(bytes32 role, address account) public override onlyOwner {
        _revokeRole(role, account);
    }

    // inner function for delegatecall
    // @Notive: relay the msg.data to impl contract, which is already encoded as per the function signature
    function _delegatecall(address impl) private returns (bytes memory) {
        (bool success, bytes memory returnData) = impl.delegatecall(msg.data);
        if (!success) {
            if (returnData.length > 0) {
                assembly {
                    revert(add(32, returnData), mload(returnData))
                }
            } else {
                revert DelegatecallFail();
            }
        }
        return returnData;
    }
}
