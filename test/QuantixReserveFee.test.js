const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Quantix Reserve Fee", function () {
  let Quantix, quantix, owner, user1, user2, reserve;
  const minter = ethers.constants.AddressZero;
  const THRESHOLD = ethers.utils.parseEther("1000");
  const FEE_SMALL = 5; // 5%
  const FEE_LARGE = 25; // 2.5% (divide by 10)
  const FEE_DENOMINATOR = 100;

  beforeEach(async function () {
    [owner, user1, user2, reserve] = await ethers.getSigners();
    Quantix = await ethers.getContractFactory("Quantix");
    quantix = await Quantix.deploy(minter.address);
    await quantix.deployed();
    await quantix.grantRole(await quantix.DEFAULT_ADMIN_ROLE(), owner.address);
    await quantix.setReserve(reserve.address);
    await quantix.grantRole(await quantix.MINTER_ROLE(), owner.address);
    // Mint tokens to user1 for testing
    await quantix.mint(user1.address, ethers.utils.parseEther("2000"));
  });

  it("applies 5% fee for transfers below threshold", async function () {
    const amount = ethers.utils.parseEther("500");
    const fee = amount.mul(FEE_SMALL).div(FEE_DENOMINATOR);
    await expect(quantix.connect(user1).transfer(user2.address, amount))
      .to.emit(quantix, "FeeCollected")
      .withArgs(user1.address, fee);
    expect(await quantix.balanceOf(reserve.address)).to.equal(fee);
    expect(await quantix.balanceOf(user2.address)).to.equal(amount.sub(fee));
  });

  it("applies 2.5% fee for transfers at or above threshold", async function () {
    const amount = ethers.utils.parseEther("1500");
    const fee = amount.mul(FEE_LARGE).div(FEE_DENOMINATOR * 2);
    await expect(quantix.connect(user1).transfer(user2.address, amount))
      .to.emit(quantix, "FeeCollected")
      .withArgs(user1.address, fee);
    expect(await quantix.balanceOf(reserve.address)).to.equal(fee);
    expect(await quantix.balanceOf(user2.address)).to.equal(amount.sub(fee));
  });

  it("does not apply fee on minting or burning", async function () {
    const mintAmount = ethers.utils.parseEther("100");
    await quantix.mint(user2.address, mintAmount);
    expect(await quantix.balanceOf(reserve.address)).to.equal(0);
    await quantix.burn(user2.address, mintAmount);
    expect(await quantix.balanceOf(reserve.address)).to.equal(0);
  });
}); 