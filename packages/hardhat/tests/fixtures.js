const { ethers } = require("hardhat");

const USDC_DECIMALS = 6;
const ONE_MILLION_USDC = ethers.utils.parseUnits("1000000", USDC_DECIMALS);

async function deployWavefront() {
  const [owner, treasury, creator, alice, bob, affiliate, other] =
    await ethers.getSigners();

  const USDC = await ethers.getContractFactory("USDC");
  const usdc = await USDC.deploy();
  await usdc.deployed();

  for (const signer of [owner, creator, alice, bob, affiliate, other]) {
    await usdc.mint(signer.address, ONE_MILLION_USDC);
  }

  const Core = await ethers.getContractFactory("Core");
  const core = await Core.connect(owner).deploy(usdc.address);
  await core.deployed();

  const Router = await ethers.getContractFactory("Router");
  const router = await Router.connect(owner).deploy(core.address);
  await router.deployed();

  const Multicall = await ethers.getContractFactory("Multicall");
  const multicall = await Multicall.connect(owner).deploy(core.address);
  await multicall.deployed();

  await core.connect(owner).setTreasury(treasury.address);

  return {
    usdc,
    core,
    router,
    multicall,
    owner,
    treasury,
    creator,
    alice,
    bob,
    affiliate,
    other,
  };
}

async function createCoin(
  router,
  usdc,
  creator,
  name = "Wave Coin",
  symbol = "WAVE",
  initialBuyUSDC = "1000"
) {
  const initialBuy = ethers.utils.parseUnits(initialBuyUSDC, USDC_DECIMALS);
  await usdc.connect(creator).approve(router.address, initialBuy);
  const tx = await router.connect(creator).createCoin(name, symbol, initialBuy);
  const receipt = await tx.wait();
  const event = receipt.events.find((e) => e.event === "Router__CoinCreated");
  const Coin = await ethers.getContractFactory("Coin");
  return Coin.attach(event.args.coin);
}

const usdc = (n) => ethers.utils.parseUnits(String(n), USDC_DECIMALS);
const wei = (n) => ethers.utils.parseEther(String(n));

module.exports = { deployWavefront, createCoin, usdc, wei, USDC_DECIMALS };
