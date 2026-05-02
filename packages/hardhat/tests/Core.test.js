const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployWavefront, usdc } = require("./fixtures");

const ZERO = ethers.constants.AddressZero;

describe("Core", function () {
  it("setTreasury onlyOwner", async function () {
    const { core, alice, bob } = await deployWavefront();
    await expect(core.connect(alice).setTreasury(bob.address)).to.be.revertedWith(
      "Ownable: caller is not the owner"
    );
  });

  it("setTreasury updates and emits", async function () {
    const { core, owner, bob } = await deployWavefront();
    await expect(core.connect(owner).setTreasury(bob.address))
      .to.emit(core, "Core__TreasurySet")
      .withArgs(bob.address);
    expect(await core.treasury()).to.eq(bob.address);
  });

  it("create reverts when coreCoinAmtRequired < MINIMUM_CORE_AMT_REQUIRED", async function () {
    const { core, usdc: u, creator } = await deployWavefront();
    await u.connect(creator).approve(core.address, usdc(1000));
    await expect(
      core.connect(creator).create("Wave", "WAVE", creator.address, usdc(1000), 0)
    ).to.be.revertedWith("Core__InsufficientCoreAmtRequired");
  });

  it("create increments index and registers the coin", async function () {
    const { core, usdc: u, router, creator } = await deployWavefront();
    expect(await core.index()).to.eq(0);

    await u.connect(creator).approve(router.address, usdc(1000));
    const tx = await router
      .connect(creator)
      .createCoin("Wave", "WAVE", usdc(1000));
    const receipt = await tx.wait();
    const event = receipt.events.find((e) => e.event === "Router__CoinCreated");
    const coinAddr = event.args.coin;

    expect(await core.index()).to.eq(1);
    expect(await core.index_Coin(1)).to.eq(coinAddr);
    expect(await core.coin_Index(coinAddr)).to.eq(1);
  });

  it("create runs initial buy, retains 1e18 coins, forwards remainder", async function () {
    const { core, usdc: u, router, creator } = await deployWavefront();

    await u.connect(creator).approve(router.address, usdc(1000));
    const tx = await router
      .connect(creator)
      .createCoin("Wave", "WAVE", usdc(1000));
    const receipt = await tx.wait();
    const event = receipt.events.find((e) => e.event === "Router__CoinCreated");
    const coinAddr = event.args.coin;

    const Coin = await ethers.getContractFactory("Coin");
    const coin = Coin.attach(coinAddr);

    // Core retains exactly 1e18 (MINIMUM_CORE_AMT_REQUIRED) coins
    expect(await coin.balanceOf(core.address)).to.eq(ethers.utils.parseEther("1"));
    // Creator has the rest of the initial buy minus what Core retained
    const creatorBalance = await coin.balanceOf(creator.address);
    expect(creatorBalance).to.be.gt(0);
  });

  it("create emits Core__CoinCreated", async function () {
    const { core, usdc: u, router, creator } = await deployWavefront();

    await u.connect(creator).approve(router.address, usdc(1000));
    const tx = await router
      .connect(creator)
      .createCoin("Wave", "WAVE", usdc(1000));
    const receipt = await tx.wait();

    const coreCreatedTopic = core.interface.getEventTopic("Core__CoinCreated");
    const coreLog = receipt.logs.find((l) => l.topics[0] === coreCreatedTopic);
    expect(coreLog).to.not.be.undefined;
    const decoded = core.interface.parseLog(coreLog);
    expect(decoded.args.name).to.eq("Wave");
    expect(decoded.args.symbol).to.eq("WAVE");
    expect(decoded.args.index).to.eq(1);
    expect(decoded.args.owner).to.eq(creator.address);
  });
});
