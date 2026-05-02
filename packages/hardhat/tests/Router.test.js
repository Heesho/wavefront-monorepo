const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployWavefront, createCoin, usdc } = require("./fixtures");

const ZERO = ethers.constants.AddressZero;

describe("Router", function () {
  it("createCoin transfers quote in and deploys via Core", async function () {
    const { router, usdc: u, creator } = await deployWavefront();

    const usdcBefore = await u.balanceOf(creator.address);
    const initialBuy = usdc(1000);
    await u.connect(creator).approve(router.address, initialBuy);
    await router.connect(creator).createCoin("Wave", "WAVE", initialBuy);

    // Creator is the initial team, so they receive the team fee back from their own buy
    const feePool = initialBuy.mul(100).div(10000);
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
    await router.connect(alice).buy(coin.address, ZERO, buyAmt, 0, 0);
    const after = await u.balanceOf(alice.address);

    // Net spent equals buyAmt (no residual stuck)
    expect(before.sub(after)).to.eq(buyAmt);
    expect(await u.balanceOf(router.address)).to.eq(0);
  });

  it("buy sets affiliate on first call only", async function () {
    const { router, usdc: u, creator, alice, affiliate, bob } =
      await deployWavefront();
    const coin = await createCoin(router, u, creator);

    expect(await router.account_Affiliate(alice.address)).to.eq(ZERO);

    const buyAmt = usdc(100);
    await u.connect(alice).approve(router.address, buyAmt.mul(2));

    await expect(router.connect(alice).buy(coin.address, affiliate.address, buyAmt, 0, 0))
      .to.emit(router, "Router__AffiliateSet")
      .withArgs(alice.address, affiliate.address);
    expect(await router.account_Affiliate(alice.address)).to.eq(affiliate.address);

    // A second buy with a different affiliate must NOT change the mapping
    const tx = await router.connect(alice).buy(coin.address, bob.address, buyAmt, 0, 0);
    const receipt = await tx.wait();
    const setEvent = receipt.events?.find((e) => e.event === "Router__AffiliateSet");
    expect(setEvent).to.be.undefined;
    expect(await router.account_Affiliate(alice.address)).to.eq(affiliate.address);
  });

  it("buy passes the persisted affiliate to Coin as provider", async function () {
    const { router, usdc: u, creator, alice, affiliate } = await deployWavefront();
    const coin = await createCoin(router, u, creator);

    // First buy: register the affiliate
    const seed = usdc(10);
    await u.connect(alice).approve(router.address, seed);
    await router.connect(alice).buy(coin.address, affiliate.address, seed, 0, 0);

    // Second buy: zero affiliate, but provider should still come from persisted mapping
    const buyAmt = usdc(1000);
    const affiliateBefore = await u.balanceOf(affiliate.address);
    await u.connect(alice).approve(router.address, buyAmt);
    await router.connect(alice).buy(coin.address, ZERO, buyAmt, 0, 0);
    const affiliateAfter = await u.balanceOf(affiliate.address);

    const feePool = buyAmt.mul(100).div(10000);
    const perRecipient = feePool.mul(2000).div(10000);
    expect(affiliateAfter.sub(affiliateBefore)).to.eq(perRecipient);
  });

  it("sell forwards quote out to msg.sender", async function () {
    const { router, usdc: u, creator, alice } = await deployWavefront();
    const coin = await createCoin(router, u, creator);

    await u.connect(alice).approve(router.address, usdc(1000));
    await router.connect(alice).buy(coin.address, ZERO, usdc(1000), 0, 0);

    const coinBalance = await coin.balanceOf(alice.address);
    await coin.connect(alice).approve(router.address, coinBalance);

    const usdcBefore = await u.balanceOf(alice.address);
    await router.connect(alice).sell(coin.address, ZERO, coinBalance, 0, 0);
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
      router.connect(alice).buy(coin.address, ZERO, usdc(100), 0, past)
    ).to.be.revertedWith("Coin__Expired");
  });

  it("withdrawStuckTokens onlyOwner", async function () {
    const { router, usdc: u, alice, bob } = await deployWavefront();
    await expect(
      router.connect(alice).withdrawStuckTokens(u.address, bob.address)
    ).to.be.revertedWith("Ownable: caller is not the owner");
  });
});
