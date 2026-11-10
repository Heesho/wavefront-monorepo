const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployWavefront, createCoin, usdc } = require("./fixtures");

describe("Router", function () {
  it("createCoin transfers quote in and deploys via Core", async function () {
    const { router, usdc: u, creator } = await deployWavefront();

    const usdcBefore = await u.balanceOf(creator.address);
    const initialBuy = usdc(1000);
    await u.connect(creator).approve(router.address, initialBuy);
    await router.connect(creator).createCoin("Wave", "WAVE", initialBuy);

    // Creator is the initial team, so they receive the team fee back from their own buy
    const feePool = initialBuy.mul(200).div(10000);
    const teamFee = feePool.mul(2000).div(10000);
    expect(await u.balanceOf(creator.address)).to.eq(
      usdcBefore.sub(initialBuy).add(teamFee)
    );
    // Router never holds residual quote (it was approved and consumed by Core)
    expect(await u.balanceOf(router.address)).to.eq(0);
  });

  it("buy refunds residual quote to msg.sender", async function () {
    const { router, usdc: u, creator, alice } = await deployWavefront();
    const coin = await createCoin(router, u, creator);

    const buyAmt = usdc(500);
    await u.connect(alice).approve(router.address, buyAmt);
    const before = await u.balanceOf(alice.address);
    await router.connect(alice).buy(coin.address, buyAmt, 0, 0);
    const after = await u.balanceOf(alice.address);

    // Net spent equals buyAmt (no residual stuck)
    expect(before.sub(after)).to.eq(buyAmt);
    expect(await u.balanceOf(router.address)).to.eq(0);
  });

  it("buy emits Router__Buy and pays only team and treasury", async function () {
    const { router, usdc: u, creator, alice, treasury } = await deployWavefront();
    const coin = await createCoin(router, u, creator);

    const buyAmt = usdc(1000);
    const teamBefore = await u.balanceOf(creator.address);
    const treasuryBefore = await u.balanceOf(treasury.address);
    const coinBefore = await u.balanceOf(coin.address);
    await u.connect(alice).approve(router.address, buyAmt);
    await expect(router.connect(alice).buy(coin.address, buyAmt, 0, 0)).to.emit(router, "Router__Buy");

    const feePool = buyAmt.mul(200).div(10000);
    const perRecipient = feePool.mul(2000).div(10000);
    expect((await u.balanceOf(creator.address)).sub(teamBefore)).to.eq(perRecipient);
    expect((await u.balanceOf(treasury.address)).sub(treasuryBefore)).to.eq(perRecipient);
    // team and treasury are the only fee recipients; everything else stays in the curve
    expect((await u.balanceOf(coin.address)).sub(coinBefore)).to.eq(buyAmt.sub(perRecipient.mul(2)));
  });

  it("sell forwards quote out to msg.sender", async function () {
    const { router, usdc: u, creator, alice } = await deployWavefront();
    const coin = await createCoin(router, u, creator);

    await u.connect(alice).approve(router.address, usdc(1000));
    await router.connect(alice).buy(coin.address, usdc(1000), 0, 0);

    const coinBalance = await coin.balanceOf(alice.address);
    await coin.connect(alice).approve(router.address, coinBalance);

    const usdcBefore = await u.balanceOf(alice.address);
    await router.connect(alice).sell(coin.address, coinBalance, 0, 0);
    const usdcAfter = await u.balanceOf(alice.address);

    expect(usdcAfter).to.be.gt(usdcBefore);
    expect(await coin.balanceOf(alice.address)).to.eq(0);
  });

  it("expired deadline propagates", async function () {
    const { router, usdc: u, creator, alice } = await deployWavefront();
    const coin = await createCoin(router, u, creator);

    await u.connect(alice).approve(router.address, usdc(100));
    const past = (await ethers.provider.getBlock("latest")).timestamp - 1;
    await expect(
      router.connect(alice).buy(coin.address, usdc(100), 0, past)
    ).to.be.revertedWith("Coin__Expired");
  });

  it("withdrawStuckTokens onlyOwner", async function () {
    const { router, usdc: u, alice, bob } = await deployWavefront();
    await expect(
      router.connect(alice).withdrawStuckTokens(u.address, bob.address)
    ).to.be.revertedWith("Ownable: caller is not the owner");
  });
});
