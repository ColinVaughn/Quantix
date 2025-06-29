// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

/// @title Quantix Stablecoin (QTX)
/// @notice ERC-20 token with mint/burn restricted to CollateralManager (minter role)
contract Quantix is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Reserve address for liquidity fees
    address public reserve;
    event ReserveUpdated(address indexed newReserve);
    event FeeCollected(address indexed from, uint256 amount);

    // Fee parameters
    uint256 public constant FEE_THRESHOLD = 1_000 * 1e18; // 1,000 QTX
    uint256 public constant FEE_SMALL = 5; // 5%
    uint256 public constant FEE_LARGE = 25; // 2.5% (divide by 10 for 2.5%)
    uint256 public constant FEE_DENOMINATOR = 100;

    // Custom errors for gas savings
    error DailyTransferLimitExceeded();
    error InvalidReserveAddress();

    constructor(address minter) ERC20("Quantix", "QTX") {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MINTER_ROLE, minter);
    }

    // Per-address daily transfer limit
    uint256 public constant DAILY_LIMIT = 10_000 * 1e18; // 10,000 QTX
    uint256 public constant WINDOW = 1 days;
    struct TransferInfo {
        uint256 amountTransferred;
        uint256 windowStart;
    }
    mapping(address => TransferInfo) public transferInfos;

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);
        // Exclude minting and burning
        if (from == address(0) || to == address(0)) {
            return;
        }
        TransferInfo storage info = transferInfos[from];
        uint256 currentTime = block.timestamp;
        if (currentTime > info.windowStart + WINDOW) {
            // Reset window
            info.windowStart = currentTime;
            info.amountTransferred = 0;
        }
        if (info.amountTransferred + amount > DAILY_LIMIT) revert DailyTransferLimitExceeded();
        info.amountTransferred += amount;
    }

    function setReserve(address _reserve) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_reserve == address(0)) revert InvalidReserveAddress();
        reserve = _reserve;
        emit ReserveUpdated(_reserve);
    }

    // Fee exemption list (DAO-controlled)
    mapping(address => bool) public isFeeExempt;
    event FeeExemptSet(address indexed account, bool isExempt);

    /// @notice Set fee exemption for an address (only DAO/admin)
    function setFeeExempt(address account, bool exempt) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isFeeExempt[account] = exempt;
        emit FeeExemptSet(account, exempt);
    }

    /// @notice Batch transfer: send to multiple recipients in one call
    function batchTransfer(address[] calldata recipients, uint256[] calldata amounts) external {
        require(recipients.length == amounts.length, "Mismatched arrays");
        for (uint256 i = 0; i < recipients.length; i++) {
            transfer(recipients[i], amounts[i]);
        }
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        // Exclude minting and burning, or if fee exempt
        if (from == address(0) || to == address(0) || reserve == address(0) || isFeeExempt[from] || isFeeExempt[to]) {
            super._transfer(from, to, amount);
            return;
        }
        uint256 fee;
        if (amount < FEE_THRESHOLD) {
            fee = (amount * FEE_SMALL) / FEE_DENOMINATOR;
        } else {
            fee = (amount * FEE_LARGE) / (FEE_DENOMINATOR * 2); // 2.5%
        }
        uint256 amountAfterFee = amount - fee;
        super._transfer(from, reserve, fee);
        super._transfer(from, to, amountAfterFee);
        emit FeeCollected(from, fee);
    }

    /// @notice Mint QTX tokens (only by minter)
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn QTX tokens (only by minter)
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }
} 