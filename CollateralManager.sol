// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Quantix.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CollateralManager for Quantix Stablecoin
/// @notice Manages ETH collateral, minting, burning, and liquidations for QTX
contract CollateralManager is Ownable, Pausable, ReentrancyGuard {
    Quantix public immutable quantix;
    uint256 public constant COLLATERALIZATION_RATIO = 150; // 150%
    uint256 public constant RATIO_PRECISION = 100;
    AggregatorV3Interface public immutable priceFeed;

    // Multi-collateral support
    struct CollateralType {
        address token; // address(0) for ETH
        address oracle; // Chainlink price feed
        uint256 minCollateralRatio; // e.g., 150 (for 150%)
        uint8 decimals; // decimals of the collateral token
        bool enabled;
        uint256 liquidationPenalty; // percent, e.g., 10 = 10%
        uint256 protocolFee; // percent, e.g., 1 = 1%
    }
    mapping(bytes32 => CollateralType) public collateralTypes; // symbol => CollateralType
    bytes32[] public collateralSymbols;

    // Vaults are now per user per collateral type
    struct Vault {
        uint256 collateral; // in token decimals
        uint256 debt;      // in QTX (18 decimals)
    }
    mapping(address => mapping(bytes32 => Vault)) public vaults; // user => symbol => Vault

    // Circuit breaker parameters (DAO-controlled)
    uint256 public maxSingleWithdrawal; // e.g., in USD (1e18)
    uint256 public maxSingleMint; // e.g., in QTX (1e18)
    uint256 public maxBlockWithdrawal; // e.g., in USD (1e18)
    uint256 public maxBlockMint; // e.g., in QTX (1e18)
    uint256 public maxPriceDropPercent; // e.g., 20 for 20%
    mapping(bytes32 => uint256) public lastOraclePrice;
    mapping(bytes32 => uint256) public blockWithdrawals;
    mapping(bytes32 => uint256) public blockMints;
    uint256 public lastCheckedBlock;

    // TWAP support (simple rolling window)
    uint256 public constant TWAP_WINDOW = 10;
    mapping(bytes32 => uint256[TWAP_WINDOW]) public priceHistory;
    mapping(bytes32 => uint256) public priceHistoryIndex;
    mapping(bytes32 => uint256) public priceHistoryCount;

    // Vault migration/upgrade path
    address public migrationContract;
    bool public migrationEnabled;
    event MigrationContractSet(address migrationContract, bool enabled);
    event VaultMigrated(address indexed user, bytes32 indexed symbol, uint256 collateral, uint256 debt);

    event CollateralTypeAdded(bytes32 indexed symbol, address token, address oracle, uint256 minRatio, uint8 decimals);
    event CollateralTypeUpdated(bytes32 indexed symbol, uint256 minRatio, bool enabled);
    event CollateralTypeRemoved(bytes32 indexed symbol);
    event CollateralDeposited(address indexed user, uint256 amount);
    event QTXMinted(address indexed user, uint256 amount);
    event QTXBurned(address indexed user, uint256 amount);
    event CollateralWithdrawn(address indexed user, uint256 amount);
    event VaultLiquidated(address indexed user, address indexed liquidator);
    event CircuitBreakerTripped(string reason);
    event CircuitBreakerParamsSet(uint256 maxSingleWithdrawal, uint256 maxSingleMint, uint256 maxBlockWithdrawal, uint256 maxBlockMint, uint256 maxPriceDropPercent);
    event LiquidationReward(address indexed liquidator, uint256 reward);
    event ProtocolFeeCollected(address indexed from, uint256 amount, bytes32 symbol);
    event VaultHealthChanged(address indexed user, bytes32 indexed symbol, uint256 newRatio, bool isSafe);
    event LiquidationWarning(address indexed user, bytes32 indexed symbol, uint256 ratio, uint256 minRatio);
    event ProtocolParameterChanged(string param, bytes32 symbol, uint256 newValue);
    event EmergencyWithdraw(address indexed to, bytes32 indexed symbol, uint256 amount);

    // Custom errors for gas savings
    error NoCollateralSent();
    error InsufficientCollateral();
    error BurnExceedsDebt();
    error WithdrawExceedsCollateral();
    error WouldBeUndercollateralized();
    error VaultIsSafe();
    error InvalidPrice();
    error ETHTransferFailed();

    constructor(address quantixAddress, address priceFeedAddress) {
        quantix = Quantix(quantixAddress);
        priceFeed = AggregatorV3Interface(priceFeedAddress);
    }

    /// @notice Add a new collateral type (onlyOwner/DAO)
    function addCollateralType(bytes32 symbol, address token, address oracle, uint256 minRatio, uint8 decimals, uint256 penalty, uint256 fee) external onlyOwner {
        require(!collateralTypes[symbol].enabled, "Already exists");
        collateralTypes[symbol] = CollateralType(token, oracle, minRatio, decimals, true, penalty, fee);
        collateralSymbols.push(symbol);
        emit CollateralTypeAdded(symbol, token, oracle, minRatio, decimals);
        emit ProtocolParameterChanged("addCollateral", symbol, minRatio);
    }

    /// @notice Update collateral type parameters (onlyOwner/DAO)
    function updateCollateralType(bytes32 symbol, uint256 minRatio, bool enabled, uint256 penalty, uint256 fee) external onlyOwner {
        require(collateralTypes[symbol].enabled, "Not exists");
        CollateralType storage c = collateralTypes[symbol];
        c.minCollateralRatio = minRatio;
        c.enabled = enabled;
        c.liquidationPenalty = penalty;
        c.protocolFee = fee;
        emit CollateralTypeUpdated(symbol, minRatio, enabled);
        emit ProtocolParameterChanged("updateCollateral", symbol, minRatio);
    }

    /// @notice Remove a collateral type (onlyOwner/DAO)
    function removeCollateralType(bytes32 symbol) external onlyOwner {
        require(collateralTypes[symbol].enabled, "Not exists");
        collateralTypes[symbol].enabled = false;
        emit CollateralTypeRemoved(symbol);
    }

    /// @notice Set circuit breaker parameters (onlyOwner/DAO)
    function setCircuitBreakerParams(
        uint256 _maxSingleWithdrawal,
        uint256 _maxSingleMint,
        uint256 _maxBlockWithdrawal,
        uint256 _maxBlockMint,
        uint256 _maxPriceDropPercent
    ) external onlyOwner {
        maxSingleWithdrawal = _maxSingleWithdrawal;
        maxSingleMint = _maxSingleMint;
        maxBlockWithdrawal = _maxBlockWithdrawal;
        maxBlockMint = _maxBlockMint;
        maxPriceDropPercent = _maxPriceDropPercent;
        emit CircuitBreakerParamsSet(_maxSingleWithdrawal, _maxSingleMint, _maxBlockWithdrawal, _maxBlockMint, _maxPriceDropPercent);
        emit ProtocolParameterChanged("circuitBreaker", 0, _maxSingleWithdrawal);
    }

    /// @notice Set migration contract and enable/disable migration (DAO only)
    function setMigrationContract(address _migrationContract, bool enabled) external onlyOwner {
        migrationContract = _migrationContract;
        migrationEnabled = enabled;
        emit MigrationContractSet(_migrationContract, enabled);
    }

    /// @notice Deposit collateral and optionally mint QTX (for any collateral type)
    function depositAndMint(bytes32 symbol, uint256 depositAmount, uint256 mintAmount) external payable whenNotPaused nonReentrant {
        CollateralType storage c = collateralTypes[symbol];
        require(c.enabled, "Collateral disabled");
        Vault storage v = vaults[msg.sender][symbol];
        if (c.token == address(0)) {
            // ETH
            require(msg.value == depositAmount && depositAmount > 0, "ETH mismatch");
        } else {
            require(msg.value == 0, "No ETH for ERC20");
            require(depositAmount > 0, "No deposit");
            IERC20(c.token).transferFrom(msg.sender, address(this), depositAmount);
        }
        v.collateral += depositAmount;
        uint256 price = _getPrice(c.oracle);
        _updateTWAP(symbol, price);
        uint256 twap = getTWAP(symbol);
        if (mintAmount > 0) {
            require(_isCollateralizedTWAP(symbol, v.collateral, v.debt + mintAmount, twap), "Insufficient collateral");
            // Protocol fee
            uint256 fee = (mintAmount * c.protocolFee) / 100;
            if (fee > 0) {
                quantix.mint(reserve, fee);
                emit ProtocolFeeCollected(msg.sender, fee, symbol);
            }
            v.debt += mintAmount;
            quantix.mint(msg.sender, mintAmount - fee);
            emit QTXMinted(msg.sender, mintAmount - fee);
        }
        // Circuit breaker: check mint
        _circuitBreaker(symbol, 0, mintAmount, price);
        emit CollateralDeposited(msg.sender, depositAmount);
        _notifyVaultHealth(msg.sender, symbol, v.collateral, v.debt, c.minCollateralRatio, twap);
    }

    /// @notice Burn QTX and withdraw collateral (for any collateral type)
    function burnAndWithdraw(bytes32 symbol, uint256 burnAmount, uint256 withdrawAmount) external whenNotPaused nonReentrant {
        CollateralType storage c = collateralTypes[symbol];
        require(c.enabled, "Collateral disabled");
        Vault storage v = vaults[msg.sender][symbol];
        if (burnAmount > v.debt) revert BurnExceedsDebt();
        if (withdrawAmount > v.collateral) revert WithdrawExceedsCollateral();
        if (burnAmount > 0) {
            quantix.burn(msg.sender, burnAmount);
            v.debt -= burnAmount;
            emit QTXBurned(msg.sender, burnAmount);
        }
        uint256 price = _getPrice(c.oracle);
        _updateTWAP(symbol, price);
        uint256 twap = getTWAP(symbol);
        if (withdrawAmount > 0) {
            require(_isCollateralizedTWAP(symbol, v.collateral - withdrawAmount, v.debt, twap), "Would be undercollateralized");
            v.collateral -= withdrawAmount;
            // Circuit breaker: check withdrawal
            uint256 withdrawalUSD = (withdrawAmount * price) / (10 ** c.decimals);
            _circuitBreaker(symbol, withdrawalUSD, 0, price);
            if (c.token == address(0)) {
                (bool sent, ) = msg.sender.call{value: withdrawAmount}("");
                if (!sent) revert ETHTransferFailed();
            } else {
                IERC20(c.token).transfer(msg.sender, withdrawAmount);
            }
            emit CollateralWithdrawn(msg.sender, withdrawAmount);
        }
        _notifyVaultHealth(msg.sender, symbol, v.collateral, v.debt, c.minCollateralRatio, twap);
    }

    /// @notice Liquidate undercollateralized vaults (for any collateral type)
    function liquidate(bytes32 symbol, address user) external whenNotPaused nonReentrant {
        CollateralType storage c = collateralTypes[symbol];
        require(c.enabled, "Collateral disabled");
        Vault storage v = vaults[user][symbol];
        uint256 price = _getPrice(c.oracle);
        _updateTWAP(symbol, price);
        uint256 twap = getTWAP(symbol);
        require(!_isCollateralizedTWAP(symbol, v.collateral, v.debt, twap), "Vault is safe");
        uint256 collateralToSeize = v.collateral;
        uint256 debtToBurn = v.debt;
        v.collateral = 0;
        v.debt = 0;
        quantix.burn(msg.sender, debtToBurn); // Liquidator must burn QTX equal to debt
        // Calculate liquidation penalty
        uint256 reward = (collateralToSeize * c.liquidationPenalty) / 100;
        uint256 toReserve = collateralToSeize - reward;
        if (c.token == address(0)) {
            if (reward > 0) {
                (bool sent, ) = msg.sender.call{value: reward}("");
                if (!sent) revert ETHTransferFailed();
                emit LiquidationReward(msg.sender, reward);
            }
            if (toReserve > 0) {
                (bool sent2, ) = reserve.call{value: toReserve}("");
                if (!sent2) revert ETHTransferFailed();
            }
        } else {
            if (reward > 0) {
                IERC20(c.token).transfer(msg.sender, reward);
                emit LiquidationReward(msg.sender, reward);
            }
            if (toReserve > 0) {
                IERC20(c.token).transfer(reserve, toReserve);
            }
        }
        emit VaultLiquidated(user, msg.sender);
    }

    /// @notice Migrate user's vault to the new contract (if enabled)
    function migrateVault(bytes32 symbol) external {
        require(migrationEnabled && migrationContract != address(0), "Migration not enabled");
        Vault storage v = vaults[msg.sender][symbol];
        require(v.collateral > 0 || v.debt > 0, "Nothing to migrate");
        // Transfer vault data to new contract
        (bool success, ) = migrationContract.call(
            abi.encodeWithSignature(
                "receiveMigratedVault(address,bytes32,uint256,uint256)",
                msg.sender,
                symbol,
                v.collateral,
                v.debt
            )
        );
        require(success, "Migration failed");
        // Clear user's vault in this contract
        v.collateral = 0;
        v.debt = 0;
        emit VaultMigrated(msg.sender, symbol, v.collateral, v.debt);
    }

    function pause() external onlyOwner {
        _pause();
    }
    function unpause() external onlyOwner {
        _unpause();
    }

    // Collateralization check for any collateral type
    function _isCollateralized(bytes32 symbol, uint256 collateral, uint256 debt) internal view returns (bool) {
        if (debt == 0) return true;
        CollateralType storage c = collateralTypes[symbol];
        uint256 price = _getPrice(c.oracle);
        uint256 collateralUSD = (collateral * price) / (10 ** c.decimals);
        return (collateralUSD * RATIO_PRECISION) / debt >= c.minCollateralRatio;
    }

    // Get price from Chainlink oracle
    function _getPrice(address oracle) internal view returns (uint256) {
        (
            ,
            int256 price,
            ,
            ,
        ) = AggregatorV3Interface(oracle).latestRoundData();
        if (price <= 0) revert InvalidPrice();
        // Chainlink returns price with 8 decimals, convert to 18 decimals
        return uint256(price) * 1e10;
    }

    /// @notice Get vault health for a user
    function getVaultHealth(address user) external view returns (
        uint256 collateral,
        uint256 debt,
        uint256 collateralizationRatio,
        bool isSafe
    ) {
        Vault storage v = vaults[user][bytes32(0)];
        collateral = v.collateral;
        debt = v.debt;
        if (debt == 0) {
            collateralizationRatio = type(uint256).max;
            isSafe = true;
        } else {
            uint256 ethPrice = _getPrice(address(priceFeed));
            uint256 collateralUSD = (collateral * ethPrice) / 1e18;
            collateralizationRatio = (collateralUSD * RATIO_PRECISION) / debt;
            isSafe = collateralizationRatio >= COLLATERALIZATION_RATIO;
        }
    }

    /// @notice Get the max QTX a user can mint with current collateral
    function maxMintable(address user) external view returns (uint256) {
        Vault storage v = vaults[user][bytes32(0)];
        uint256 ethPrice = _getPrice(address(priceFeed));
        uint256 collateralUSD = (v.collateral * ethPrice) / 1e18;
        uint256 maxDebt = (collateralUSD * RATIO_PRECISION) / COLLATERALIZATION_RATIO;
        if (maxDebt > v.debt) {
            return maxDebt - v.debt;
        } else {
            return 0;
        }
    }

    // Internal: check and update circuit breaker for withdrawals/mints and price drops
    function _circuitBreaker(bytes32 symbol, uint256 withdrawalUSD, uint256 mintAmount, uint256 price) internal {
        // Reset block counters if new block
        if (block.number != lastCheckedBlock) {
            for (uint256 i = 0; i < collateralSymbols.length; i++) {
                blockWithdrawals[collateralSymbols[i]] = 0;
                blockMints[collateralSymbols[i]] = 0;
            }
            lastCheckedBlock = block.number;
        }
        // Check single withdrawal
        if (withdrawalUSD > maxSingleWithdrawal && maxSingleWithdrawal > 0) {
            _pause();
            emit CircuitBreakerTripped("Single withdrawal too large");
        }
        // Check single mint
        if (mintAmount > maxSingleMint && maxSingleMint > 0) {
            _pause();
            emit CircuitBreakerTripped("Single mint too large");
        }
        // Update and check block totals
        blockWithdrawals[symbol] += withdrawalUSD;
        blockMints[symbol] += mintAmount;
        if (blockWithdrawals[symbol] > maxBlockWithdrawal && maxBlockWithdrawal > 0) {
            _pause();
            emit CircuitBreakerTripped("Block withdrawals too large");
        }
        if (blockMints[symbol] > maxBlockMint && maxBlockMint > 0) {
            _pause();
            emit CircuitBreakerTripped("Block mints too large");
        }
        // Check price drop
        if (lastOraclePrice[symbol] > 0 && maxPriceDropPercent > 0) {
            uint256 prev = lastOraclePrice[symbol];
            uint256 drop = prev > price ? ((prev - price) * 100) / prev : 0;
            if (drop >= maxPriceDropPercent) {
                _pause();
                emit CircuitBreakerTripped("Oracle price drop");
            }
        }
        lastOraclePrice[symbol] = price;
    }

    // Collateralization check using TWAP
    function _isCollateralizedTWAP(bytes32 symbol, uint256 collateral, uint256 debt, uint256 twap) internal view returns (bool) {
        if (debt == 0) return true;
        CollateralType storage c = collateralTypes[symbol];
        uint256 collateralUSD = (collateral * twap) / (10 ** c.decimals);
        return (collateralUSD * RATIO_PRECISION) / debt >= c.minCollateralRatio;
    }

    /// @notice Update TWAP for a collateral symbol
    function _updateTWAP(bytes32 symbol, uint256 newPrice) internal {
        uint256 idx = priceHistoryIndex[symbol];
        priceHistory[symbol][idx] = newPrice;
        priceHistoryIndex[symbol] = (idx + 1) % TWAP_WINDOW;
        if (priceHistoryCount[symbol] < TWAP_WINDOW) {
            priceHistoryCount[symbol]++;
        }
    }

    /// @notice Get current TWAP for a collateral symbol
    function getTWAP(bytes32 symbol) public view returns (uint256) {
        uint256 count = priceHistoryCount[symbol];
        if (count == 0) return 0;
        uint256 sum = 0;
        for (uint256 i = 0; i < count; i++) {
            sum += priceHistory[symbol][i];
        }
        return sum / count;
    }

    // Internal: emit vault health and liquidation warning events
    function _notifyVaultHealth(address user, bytes32 symbol, uint256 collateral, uint256 debt, uint256 minRatio, uint256 twap) internal {
        if (debt == 0) return;
        uint256 ratio = (collateral * twap * RATIO_PRECISION) / (debt * (10 ** collateralTypes[symbol].decimals));
        bool isSafe = ratio >= minRatio;
        emit VaultHealthChanged(user, symbol, ratio, isSafe);
        // Liquidation warning if within 5% of min ratio
        if (isSafe && ratio < minRatio + (minRatio / 20)) {
            emit LiquidationWarning(user, symbol, ratio, minRatio);
        }
    }

    /// @notice Emergency withdraw all collateral of a given type to a specified address (DAO only, only when paused)
    function emergencyWithdraw(address to, bytes32 symbol) external onlyOwner whenPaused {
        CollateralType storage c = collateralTypes[symbol];
        require(c.enabled, "Collateral disabled");
        uint256 total;
        if (c.token == address(0)) {
            total = address(this).balance;
            (bool sent, ) = to.call{value: total}("");
            require(sent, "ETH transfer failed");
        } else {
            total = IERC20(c.token).balanceOf(address(this));
            IERC20(c.token).transfer(to, total);
        }
        emit EmergencyWithdraw(to, symbol, total);
    }

    // Fallback to accept ETH
    receive() external payable {}
} 