const { ethers } = require("hardhat");
const hre = require("hardhat");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ===== SETTINGS ============================================================
// Set the treasury that should receive protocol fees. Leave empty to skip
// the setTreasury call.
const TREASURY_ADDRESS = process.env.TREASURY_ADDRESS || "";

// On non-mainnet networks (or when no quote address is provided), a USDC
// mock is deployed and used as the quote currency.
const QUOTE_ADDRESS = process.env.QUOTE_ADDRESS || "";
// ===========================================================================

async function verify(address, args, contractPath) {
  for (let i = 0; i < 5; i++) {
    try {
      await hre.run("verify:verify", {
        address,
        constructorArguments: args,
        ...(contractPath ? { contract: contractPath } : {}),
      });
      return;
    } catch (e) {
      if (String(e).includes("Already Verified")) return;
      console.warn(`verify retry ${i + 1}: ${e.message || e}`);
      await sleep(15000);
    }
  }
  console.warn(`verify failed for ${address} after retries`);
}

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deployer: ${deployer.address}`);
  console.log(`Network: ${hre.network.name}`);

  let quoteAddress = QUOTE_ADDRESS;
  if (!quoteAddress) {
    console.log("\nDeploying USDC mock as quote currency...");
    const USDC = await ethers.getContractFactory("USDC");
    const usdc = await USDC.deploy();
    await usdc.deployed();
    quoteAddress = usdc.address;
    console.log(`  USDC mock: ${quoteAddress}`);
    await sleep(5000);
    await verify(usdc.address, [], "contracts/mocks/USDC.sol:USDC");
  } else {
    console.log(`Quote currency: ${quoteAddress}`);
  }

  console.log("\nDeploying Core...");
  const Core = await ethers.getContractFactory("Core");
  const core = await Core.deploy(quoteAddress);
  await core.deployed();
  console.log(`  Core: ${core.address}`);
  await sleep(5000);
  await verify(core.address, [quoteAddress]);

  console.log("\nDeploying Router...");
  const Router = await ethers.getContractFactory("Router");
  const router = await Router.deploy(core.address);
  await router.deployed();
  console.log(`  Router: ${router.address}`);
  await sleep(5000);
  await verify(router.address, [core.address]);

  console.log("\nDeploying Multicall...");
  const Multicall = await ethers.getContractFactory("Multicall");
  const multicall = await Multicall.deploy(core.address);
  await multicall.deployed();
  console.log(`  Multicall: ${multicall.address}`);
  await sleep(5000);
  await verify(multicall.address, [core.address]);

  if (TREASURY_ADDRESS) {
    console.log(`\nSetting treasury to ${TREASURY_ADDRESS}...`);
    const tx = await core.setTreasury(TREASURY_ADDRESS);
    await tx.wait();
    console.log("  Done");
  } else {
    console.log("\nSkipping setTreasury (TREASURY_ADDRESS not set)");
  }

  console.log("\nDeployment summary");
  console.log("==================");
  console.log(`Quote (USDC):   ${quoteAddress}`);
  console.log(`Core:           ${core.address}`);
  console.log(`Router:         ${router.address}`);
  console.log(`Multicall:      ${multicall.address}`);
  if (TREASURY_ADDRESS) console.log(`Treasury:       ${TREASURY_ADDRESS}`);
}

main()
  .then(() => process.exit(0))
  .catch((e) => {
    console.error(e);
    process.exit(1);
  });
