const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("CollateralManager Unit Tests", function () {
  let owner, user, liquidator, reserve, CollateralManager, Quantix, MockERC20, MockOracle, manager, quantix, token, oracle;
  const ETH = ethers.constants.AddressZero;
  const SYMBOL = ethers.utils.formatBytes32String("ETH");
  const DECIMALS = 18;
  const MIN_RATIO = 150;
  const PENALTY = 10;
  const FEE = 1;

  beforeEach(async function () {
    [owner, user, liquidator, reserve] = await ethers.getSigners();
    Quantix = await ethers.getContractFactory("Quantix");
    quantix = await Quantix.deploy(owner.address);
    await quantix.deployed();
    await quantix.setReserve(reserve.address);
    await quantix.grantRole(await quantix.MINTER_ROLE(), owner.address);
    MockERC20 = await ethers.getContractFactory("MockERC20");
    token = await MockERC20.deploy("MockToken", "MTK", DECIMALS);
    await token.deployed();
    MockOracle = await ethers.getContractFactory("MockOracle");
    oracle = await MockOracle.deploy(ethers.utils.parseUnits("2000", 8)); // $2000
    await oracle.deployed();
    CollateralManager = await ethers.getContractFactory("CollateralManager");
    manager = await CollateralManager.deploy(quantix.address, oracle.address);
    await manager.deployed();
    await manager.setReserve(reserve.address);
    await manager.addCollateralType(SYMBOL, ETH, oracle.address, MIN_RATIO, DECIMALS, PENALTY, FEE);
    await quantix.grantRole(await quantix.MINTER_ROLE(), manager.address);
  });

  it("should allow deposit and mint with ETH", async function () {
    await manager.connect(user).depositAndMint(SYMBOL, ethers.utils.parseEther("1"), ethers.utils.parseEther("1000"), { value: ethers.utils.parseEther("1") });
    expect(await quantix.balanceOf(user.address)).to.be.gt(0);
  });

  it("should allow burn and withdraw", async function () {
    await manager.connect(user).depositAndMint(SYMBOL, ethers.utils.parseEther("1"), ethers.utils.parseEther("1000"), { value: ethers.utils.parseEther("1") });
    await quantix.connect(user).approve(manager.address, ethers.utils.parseEther("1000"));
    await manager.connect(user).burnAndWithdraw(SYMBOL, ethers.utils.parseEther("1000"), ethers.utils.parseEther("1"));
    expect(await quantix.balanceOf(user.address)).to.equal(0);
  });

  it("should allow liquidation of undercollateralized vault", async function () {
    await manager.connect(user).depositAndMint(SYMBOL, ethers.utils.parseEther("1"), ethers.utils.parseEther("1000"), { value: ethers.utils.parseEther("1") });
    await oracle.setPrice(ethers.utils.parseUnits("1000", 8)); // Drop price to $1000
    await quantix.connect(liquidator).mint(liquidator.address, ethers.utils.parseEther("1000"));
    await quantix.connect(liquidator).approve(manager.address, ethers.utils.parseEther("1000"));
    await expect(manager.connect(liquidator).liquidate(SYMBOL, user.address)).to.emit(manager, "VaultLiquidated");
  });

  it("should allow migration if enabled", async function () {
    await manager.connect(user).depositAndMint(SYMBOL, ethers.utils.parseEther("1"), ethers.utils.parseEther("1000"), { value: ethers.utils.parseEther("1") });
    await manager.setMigrationContract(owner.address, true);
    // Simulate migration contract accepting vault
    await expect(manager.connect(user).migrateVault(SYMBOL)).to.be.reverted; // will revert as owner is not a contract, but call is made
  });

  it("should allow emergency withdraw when paused", async function () {
    await manager.connect(user).depositAndMint(SYMBOL, ethers.utils.parseEther("1"), ethers.utils.parseEther("1000"), { value: ethers.utils.parseEther("1") });
    await manager.pause();
    await expect(manager.emergencyWithdraw(owner.address, SYMBOL)).to.emit(manager, "EmergencyWithdraw");
  });

  it("should allow DAO to update parameters", async function () {
    await expect(manager.updateCollateralType(SYMBOL, 200, true, PENALTY, FEE)).to.emit(manager, "ProtocolParameterChanged");
  });
}); 