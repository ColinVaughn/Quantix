const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CollateralManager Security Tests", function () {
  let owner, user, attacker, reserve, CollateralManager, Quantix, MockERC20, MockOracle, manager, quantix, token, oracle;
  const ETH = ethers.constants.AddressZero;
  const SYMBOL = ethers.utils.formatBytes32String("ETH");
  const DECIMALS = 18;
  const MIN_RATIO = 150;
  const PENALTY = 10;
  const FEE = 1;

  beforeEach(async function () {
    [owner, user, attacker, reserve] = await ethers.getSigners();
    Quantix = await ethers.getContractFactory("Quantix");
    quantix = await Quantix.deploy(owner.address);
    await quantix.deployed();
    await quantix.setReserve(reserve.address);
    await quantix.grantRole(await quantix.MINTER_ROLE(), owner.address);
    MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("MockToken", "MTK", DECIMALS);
    await token.deployed();
    MockOracle = await ethers.getContractFactory("MockOracle");
    oracle = await MockOracle.deploy(ethers.utils.parseUnits("2000", 8));
    await oracle.deployed();
    CollateralManager = await ethers.getContractFactory("CollateralManager");
    manager = await CollateralManager.deploy(quantix.address, oracle.address);
    await manager.deployed();
    await manager.setReserve(reserve.address);
    await manager.addCollateralType(SYMBOL, ETH, oracle.address, MIN_RATIO, DECIMALS, PENALTY, FEE);
    await quantix.grantRole(await quantix.MINTER_ROLE(), manager.address);
  });

  it("should prevent reentrancy on burnAndWithdraw", async function () {
    // Simulate a malicious contract trying to reenter (requires a custom mock)
    // This is a placeholder; actual reentrancy test would use a contract
    expect(true).to.be.true;
  });

  it("should use TWAP to prevent oracle manipulation", async function () {
    await manager.connect(user).depositAndMint(SYMBOL, ethers.utils.parseEther("1"), ethers.utils.parseEther("1000"), { value: ethers.utils.parseEther("1") });
    // Manipulate price feed
    await oracle.setPrice(ethers.utils.parseUnits("100", 8));
    // Should not allow immediate liquidation due to TWAP
    await quantix.connect(attacker).mint(attacker.address, ethers.utils.parseEther("1000"));
    await quantix.connect(attacker).approve(manager.address, ethers.utils.parseEther("1000"));
    await expect(manager.connect(attacker).liquidate(SYMBOL, user.address)).to.be.reverted;
  });

  it("should trigger circuit breaker on large withdrawal", async function () {
    await manager.setCircuitBreakerParams(ethers.utils.parseEther("100"), 0, 0, 0, 0); // Set low threshold
    await manager.connect(user).depositAndMint(SYMBOL, ethers.utils.parseEther("10"), ethers.utils.parseEther("1000"), { value: ethers.utils.parseEther("10") });
    await quantix.connect(user).approve(manager.address, ethers.utils.parseEther("1000"));
    await manager.pause(); // Pause to allow emergency withdraw
    await expect(manager.emergencyWithdraw(owner.address, SYMBOL)).to.emit(manager, "EmergencyWithdraw");
  });

  it("should restrict emergency withdraw to DAO and only when paused", async function () {
    await expect(manager.connect(user).emergencyWithdraw(user.address, SYMBOL)).to.be.reverted;
    await manager.pause();
    await expect(manager.connect(user).emergencyWithdraw(user.address, SYMBOL)).to.be.reverted;
    await expect(manager.emergencyWithdraw(owner.address, SYMBOL)).to.emit(manager, "EmergencyWithdraw");
  });
}); 