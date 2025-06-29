// scripts/deploy.js
const { ethers } = require("hardhat");

async function main() {
  // Replace with your addresses
  const deployer = "YOUR_DEPLOYER_ADDRESS";
  const priceFeed = "CHAINLINK_ETH_USD_FEED_ADDRESS"; // e.g., Goerli: 0xD4a33860578De61DBAbDc8BFdb98FD742fA7028e
  const daoMultisig = "DAO_MULTISIG_ADDRESS";
  const minDelay = 2 * 24 * 60 * 60; // 2 days

  // 1. Deploy Quantix (pass a dummy minter, will update after CollateralManager is deployed)
  const Quantix = await ethers.getContractFactory("Quantix");
  const quantix = await Quantix.deploy(deployer);
  await quantix.deployed();
  console.log("Quantix deployed to:", quantix.address);

  // 2. Deploy CollateralManager
  const CollateralManager = await ethers.getContractFactory("CollateralManager");
  const collateralManager = await CollateralManager.deploy(quantix.address, priceFeed);
  await collateralManager.deployed();
  console.log("CollateralManager deployed to:", collateralManager.address);

  // 3. Set CollateralManager as minter
  const MINTER_ROLE = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("MINTER_ROLE"));
  let tx = await quantix.grantRole(MINTER_ROLE, collateralManager.address);
  await tx.wait();

  // 4. Deploy TimelockController
  const proposers = [daoMultisig];
  const executors = [daoMultisig];
  const TimelockController = await ethers.getContractFactory("TimelockController");
  const timelock = await TimelockController.deploy(minDelay, proposers, executors);
  await timelock.deployed();
  console.log("TimelockController deployed to:", timelock.address);

  // 5. Deploy QuantixGovernor
  const QuantixGovernor = await ethers.getContractFactory("QuantixGovernor");
  const governor = await QuantixGovernor.deploy(quantix.address, timelock.address);
  await governor.deployed();
  console.log("QuantixGovernor deployed to:", governor.address);

  // 6. Transfer admin roles to TimelockController
  const DEFAULT_ADMIN_ROLE = ethers.constants.HashZero;
  tx = await quantix.grantRole(DEFAULT_ADMIN_ROLE, timelock.address);
  await tx.wait();
  tx = await quantix.renounceRole(DEFAULT_ADMIN_ROLE, deployer);
  await tx.wait();
  tx = await collateralManager.transferOwnership(timelock.address);
  await tx.wait();

  console.log("Deployment and configuration complete.");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}); 