const { expect } = require("chai");
const { ethers } = require("hardhat");
const { deployWavefront, createCoin, usdc, wei } = require("./fixtures");

const ZERO = ethers.constants.AddressZero;

describe("Coin", function () {
  describe("buy", function () {
    it("reverts when input is below MIN_TRADE_SIZE", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, 999);
      await expect(
        coin.connect(alice).buy(999, 0, 0, alice.address, ZERO)
      ).to.be.revertedWith("Coin__MinTradeSize");
    });

    it("reverts after deadline", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      const past = (await ethers.provider.getBlock("latest")).timestamp - 1;
      await u.connect(alice).approve(coin.address, usdc(100));
      await expect(
        coin.connect(alice).buy(usdc(100), 0, past, alice.address, ZERO)
      ).to.be.revertedWith("Coin__Expired");
    });

    it("reverts on slippage", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(100));
      // Demand absurdly large coin output to trigger slippage
      await expect(
        coin.connect(alice).buy(usdc(100), wei(1_000_000_000), 0, alice.address, ZERO)
      ).to.be.revertedWith("Coin__Slippage");
    });

    it("mints expected coin amount and updates reserves", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      const reservesBefore = {
        real: await coin.reserveRealQuoteWad(),
        virt: await coin.reserveVirtQuoteWad(),
        coin: await coin.reserveCoinAmt(),
      };

      const buyAmount = usdc(500);
      await u.connect(alice).approve(coin.address, buyAmount);
      await coin.connect(alice).buy(buyAmount, 0, 0, alice.address, ZERO);

      const balance = await coin.balanceOf(alice.address);
      expect(balance).to.be.gt(0);

      const reservesAfter = {
        real: await coin.reserveRealQuoteWad(),
        virt: await coin.reserveVirtQuoteWad(),
        coin: await coin.reserveCoinAmt(),
      };

      // Real reserves grow, coin reserves shrink
      expect(reservesAfter.real).to.be.gt(reservesBefore.real);
      expect(reservesAfter.coin).to.be.lt(reservesBefore.coin);
    });
  });

  describe("fee distribution", function () {
    it("splits fees: provider, team, treasury, heal", async function () {
      const { usdc: u, router, creator, alice, affiliate, treasury } =
        await deployWavefront();
      const coin = await createCoin(router, u, creator);

      const treasuryBefore = await u.balanceOf(treasury.address);
      const teamBefore = await u.balanceOf(creator.address);
      const affiliateBefore = await u.balanceOf(affiliate.address);
      const virtBefore = await coin.reserveVirtQuoteWad();

      const buyAmount = usdc(1000);
      await u.connect(alice).approve(coin.address, buyAmount);
      await coin.connect(alice).buy(buyAmount, 0, 0, alice.address, affiliate.address);

      const treasuryDelta = (await u.balanceOf(treasury.address)).sub(treasuryBefore);
      const teamDelta = (await u.balanceOf(creator.address)).sub(teamBefore);
      const affiliateDelta = (await u.balanceOf(affiliate.address)).sub(affiliateBefore);
      const virtAfter = await coin.reserveVirtQuoteWad();

      // FEE = 100 / DIVISOR = 10000 → 1% of trade is the fee pool
      // FEE_AMOUNT = 2000 / DIVISOR = 10000 → 20% of fee pool per recipient
      // Fee pool = 1000 * 0.01 = 10 USDC. Each recipient gets 2 USDC. Heal gets 4 USDC.
      const feePool = buyAmount.mul(100).div(10000); // 10 USDC
      const perRecipient = feePool.mul(2000).div(10000); // 2 USDC

      expect(affiliateDelta).to.eq(perRecipient);
      expect(teamDelta).to.eq(perRecipient);
      expect(treasuryDelta).to.eq(perRecipient);
      // Virt reserves grew (heal happened with the leftover ~4 USDC)
      expect(virtAfter).to.be.gt(virtBefore);
    });

    it("sends provider's share to heal when affiliate is zero", async function () {
      const { usdc: u, router, creator, alice, treasury } =
        await deployWavefront();
      const coin = await createCoin(router, u, creator);

      const teamBefore = await u.balanceOf(creator.address);
      const treasuryBefore = await u.balanceOf(treasury.address);

      const buyAmount = usdc(1000);
      await u.connect(alice).approve(coin.address, buyAmount);
      await coin.connect(alice).buy(buyAmount, 0, 0, alice.address, ZERO);

      const teamDelta = (await u.balanceOf(creator.address)).sub(teamBefore);
      const treasuryDelta = (await u.balanceOf(treasury.address)).sub(treasuryBefore);
      const feePool = buyAmount.mul(100).div(10000);
      const perRecipient = feePool.mul(2000).div(10000);

      expect(teamDelta).to.eq(perRecipient);
      expect(treasuryDelta).to.eq(perRecipient);
      // No provider fee; the provider's share is healed instead
    });

    it("sends treasury's share to heal when treasury is unset", async function () {
      const { usdc: u, router, creator, alice, owner, affiliate } =
        await deployWavefront();
      // Unset treasury
      await (await ethers.getContractAt("Core", await router.core(), owner)).setTreasury(ZERO);
      const coin = await createCoin(router, u, creator);

      const teamBefore = await u.balanceOf(creator.address);
      const affiliateBefore = await u.balanceOf(affiliate.address);

      const buyAmount = usdc(1000);
      await u.connect(alice).approve(coin.address, buyAmount);
      await coin.connect(alice).buy(buyAmount, 0, 0, alice.address, affiliate.address);

      const teamDelta = (await u.balanceOf(creator.address)).sub(teamBefore);
      const affiliateDelta = (await u.balanceOf(affiliate.address)).sub(affiliateBefore);
      const feePool = buyAmount.mul(100).div(10000);
      const perRecipient = feePool.mul(2000).div(10000);

      expect(teamDelta).to.eq(perRecipient);
      expect(affiliateDelta).to.eq(perRecipient);
    });
  });

  describe("sell", function () {
    it("burns sender's coins and transfers quote", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(1000));
      await coin.connect(alice).buy(usdc(1000), 0, 0, alice.address, ZERO);

      const coinBalance = await coin.balanceOf(alice.address);
      const usdcBefore = await u.balanceOf(alice.address);

      await coin.connect(alice).sell(coinBalance, 0, 0, alice.address, ZERO);

      expect(await coin.balanceOf(alice.address)).to.eq(0);
      expect(await u.balanceOf(alice.address)).to.be.gt(usdcBefore);
    });

    it("reverts on slippage", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(1000));
      await coin.connect(alice).buy(usdc(1000), 0, 0, alice.address, ZERO);

      const coinBalance = await coin.balanceOf(alice.address);
      await expect(
        coin.connect(alice).sell(coinBalance, usdc(1_000_000), 0, alice.address, ZERO)
      ).to.be.revertedWith("Coin__Slippage");
    });

    it("reverts on min trade size", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await expect(
        coin.connect(alice).sell(999, 0, 0, alice.address, ZERO)
      ).to.be.revertedWith("Coin__MinTradeSize");
    });
  });

  describe("borrow / repay", function () {
    it("allows borrowing up to credit limit", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(1000));
      await coin.connect(alice).buy(usdc(1000), 0, 0, alice.address, ZERO);

      const credit = await coin.getAccountCredit(alice.address);
      expect(credit).to.be.gt(0);

      await coin.connect(alice).borrow(alice.address, credit);
      expect(await coin.account_DebtRaw(alice.address)).to.eq(credit);
      expect(await coin.totalDebtRaw()).to.eq(credit);
    });

    it("reverts when borrow exceeds credit", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(1000));
      await coin.connect(alice).buy(usdc(1000), 0, 0, alice.address, ZERO);

      const credit = await coin.getAccountCredit(alice.address);
      await expect(
        coin.connect(alice).borrow(alice.address, credit.add(1))
      ).to.be.revertedWith("Coin__CreditExceeded");
    });

    it("locks collateral while debt is held", async function () {
      const { usdc: u, router, creator, alice, bob } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(1000));
      await coin.connect(alice).buy(usdc(1000), 0, 0, alice.address, ZERO);

      const credit = await coin.getAccountCredit(alice.address);
      await coin.connect(alice).borrow(alice.address, credit);

      const fullBalance = await coin.balanceOf(alice.address);
      // Transferring the full balance must fail because some is locked as collateral
      await expect(
        coin.connect(alice).transfer(bob.address, fullBalance)
      ).to.be.revertedWith("Coin__CollateralLocked");
    });

    it("repay reduces debt and unlocks collateral", async function () {
      const { usdc: u, router, creator, alice, bob } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(1000));
      await coin.connect(alice).buy(usdc(1000), 0, 0, alice.address, ZERO);

      const credit = await coin.getAccountCredit(alice.address);
      await coin.connect(alice).borrow(alice.address, credit);

      await u.connect(alice).approve(coin.address, credit);
      await coin.connect(alice).repay(alice.address, credit);

      expect(await coin.account_DebtRaw(alice.address)).to.eq(0);
      // Now full balance is transferable
      const fullBalance = await coin.balanceOf(alice.address);
      await coin.connect(alice).transfer(bob.address, fullBalance);
      expect(await coin.balanceOf(bob.address)).to.eq(fullBalance);
    });
  });

  describe("heal", function () {
    it("accepts quote and shifts reserves", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      const realBefore = await coin.reserveRealQuoteWad();
      const virtBefore = await coin.reserveVirtQuoteWad();

      await u.connect(alice).approve(coin.address, usdc(100));
      await coin.connect(alice).heal(usdc(100));

      expect(await coin.reserveRealQuoteWad()).to.be.gt(realBefore);
      expect(await coin.reserveVirtQuoteWad()).to.be.gt(virtBefore);
    });

    it("reverts on zero input", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);
      await expect(coin.connect(alice).heal(0)).to.be.revertedWith("Coin__ZeroInput");
    });
  });

  describe("burn", function () {
    it("reduces user balance and shifts reserves", async function () {
      const { usdc: u, router, creator, alice } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await u.connect(alice).approve(coin.address, usdc(1000));
      await coin.connect(alice).buy(usdc(1000), 0, 0, alice.address, ZERO);

      const balance = await coin.balanceOf(alice.address);
      const maxSupplyBefore = await coin.maxSupply();
      const reserveBefore = await coin.reserveCoinAmt();

      const burnAmt = balance.div(2);
      await coin.connect(alice).burn(burnAmt);

      expect(await coin.balanceOf(alice.address)).to.eq(balance.sub(burnAmt));
      expect(await coin.maxSupply()).to.be.lt(maxSupplyBefore);
      expect(await coin.reserveCoinAmt()).to.be.lt(reserveBefore);
    });
  });

  describe("ownership and setTeam", function () {
    it("creator becomes owner and initial team", async function () {
      const { usdc: u, router, creator } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      expect(await coin.owner()).to.eq(creator.address);
      expect(await coin.team()).to.eq(creator.address);
    });

    it("setTeam reverts when called by non-owner", async function () {
      const { usdc: u, router, creator, bob } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await expect(
        coin.connect(bob).setTeam(bob.address)
      ).to.be.revertedWith("Ownable: caller is not the owner");
    });

    it("setTeam reverts on address(0)", async function () {
      const { usdc: u, router, creator } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await expect(
        coin.connect(creator).setTeam(ZERO)
      ).to.be.revertedWith("Coin__ZeroTo");
    });

    it("setTeam updates team and emits event", async function () {
      const { usdc: u, router, creator, bob } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await expect(coin.connect(creator).setTeam(bob.address))
        .to.emit(coin, "Coin__TeamSet")
        .withArgs(bob.address);
      expect(await coin.team()).to.eq(bob.address);
    });

    it("team fees route to current team after setTeam", async function () {
      const { usdc: u, router, creator, alice, bob } = await deployWavefront();
      const coin = await createCoin(router, u, creator);

      await coin.connect(creator).setTeam(bob.address);

      const bobBefore = await u.balanceOf(bob.address);
      const buyAmount = usdc(1000);
      await u.connect(alice).approve(coin.address, buyAmount);
      await coin.connect(alice).buy(buyAmount, 0, 0, alice.address, ZERO);

      const bobDelta = (await u.balanceOf(bob.address)).sub(bobBefore);
      const feePool = buyAmount.mul(100).div(10000);
      const perRecipient = feePool.mul(2000).div(10000);
      expect(bobDelta).to.eq(perRecipient);
    });
  });
});
