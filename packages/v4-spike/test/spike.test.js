// Feasibility spike: runs the same trade sequence against
//   (a) the current wavefront contracts (Core / Router / Coin, loaded from packages/hardhat artifacts)
//   (b) a real Uniswap v4 PoolManager with WavefrontHook
// and compares outputs, prices, floor, supply and credit.
const { expect } = require("chai");
const { ethers, network } = require("hardhat");
const path = require("path");

const TICK_SPACING = Number(process.env.TICK_SPACING || 1);
// One tick is 0.01% of price; the floor is snapped up to a usable tick, so parity is bounded by spacing.
const TOL = Number(process.env.TOL || (TICK_SPACING * 1.5e-4));
// Credit is rounded to ticks, so "the max" is found by trying fractions of the closed-form credit.
const BORROW_STEPS = [9990, 9950, 9900, 9750, 9500, 9000, 8000, 6500, 5000, 3000];

const refArtifact = (file, name) =>
  require(path.join(__dirname, "../../hardhat/artifacts/contracts", file, `${name}.json`));

const big = (x) => BigInt(x.toString());
const usdc = (n) => ethers.utils.parseUnits(String(n), 6);
const rel = (a, b) => {
  a = big(a); b = big(b);
  if (b === 0n) return a === 0n ? 0 : Infinity;
  const d = a > b ? a - b : b - a;
  return Number((d * 10n ** 12n) / b) / 1e12;
};
// sqrtPriceX96 (raw quote per raw coin) -> wavefront-style WAD price (quote WAD per coin WAD)
const priceWad = (sqrtX96) => (big(sqrtX96) ** 2n * 10n ** 30n) / 2n ** 192n;
const fmtUsd = (x) => (Number(big(x)) / 1e6).toFixed(6);
const fmtPct = (x) => (x * 100).toFixed(5) + "%";

// BEFORE_INITIALIZE (1<<13) | BEFORE_ADD_LIQUIDITY (1<<11) | AFTER_SWAP (1<<6) — no return-delta flags
const HOOK_ADDRESS = "0x" + "44".repeat(18) + "2840";

describe(`wavefront on Uniswap v4 (tickSpacing ${TICK_SPACING})`, function () {
  let owner, treasury, creator, alice, bob;
  let pm, quote, hook, router, coin, key; // v4 side
  let rUsdc, rCore, rRouter, rCoin; // reference side
  const gas = {};
  let maxSwapGas = 0;
  const track = (receipt) => {
    maxSwapGas = Math.max(maxSwapGas, receipt.gasUsed.toNumber());
    return receipt;
  };
  const rows = [];
  const record = (label, v4, ref) => {
    const d = rel(v4, ref);
    rows.push({ check: label, v4: v4.toString(), reference: ref.toString(), diff: fmtPct(d) });
    return d;
  };

  const v4State = async () => {
    const m = await hook.market(coin.address);
    return {
      price: priceWad(m.sqrtPriceX96),
      floor: priceWad(m.floorSqrtX96),
      supply: big(await hook.effectiveSupply(coin.address)),
      m,
    };
  };
  const refState = async () => ({
    price: big(await rCoin.getMarketPrice()),
    floor: big(await rCoin.getFloorPrice()),
    supply: big(await rCoin.maxSupply()),
  });
  const compareState = async (label) => {
    const a = await v4State();
    const b = await refState();
    expect(record(`${label}: market price`, a.price, b.price)).to.be.lt(TOL);
    expect(record(`${label}: floor price`, a.floor, b.floor)).to.be.lt(TOL);
    expect(record(`${label}: max supply`, a.supply, b.supply)).to.be.lt(TOL);
  };

  // largest fraction of the closed-form credit the hook will actually lend
  const borrowMax = async (signer) => {
    const credit = await hook.creditOf(coin.address, signer.address);
    for (const bps of BORROW_STEPS) {
      const amount = credit.mul(bps).div(10000);
      try {
        await hook.connect(signer).callStatic.borrow(coin.address, amount, signer.address);
      } catch (e) {
        continue;
      }
      const tx = await hook.connect(signer).borrow(coin.address, amount, signer.address);
      return { amount, bps, receipt: await tx.wait() };
    }
    throw new Error("no borrow fraction succeeded");
  };

  const v4Buy = async (signer, amount) => {
    const hookData = "0x";
    const before = await coin.balanceOf(signer.address);
    const tx = await router.connect(signer).swapExactIn(key, false, amount, hookData);
    const receipt = track(await tx.wait());
    return { out: (await coin.balanceOf(signer.address)).sub(before), receipt };
  };
  const v4Sell = async (signer, amount) => {
    const hookData = "0x";
    const before = await quote.balanceOf(signer.address);
    const tx = await router.connect(signer).swapExactIn(key, true, amount, hookData);
    const receipt = track(await tx.wait());
    return { out: (await quote.balanceOf(signer.address)).sub(before), receipt };
  };
  const refBuy = async (signer, amount) => {
    const before = await rCoin.balanceOf(signer.address);
    const tx = await rRouter.connect(signer).buy(rCoin.address, amount, 0, 0);
    const receipt = await tx.wait();
    return { out: (await rCoin.balanceOf(signer.address)).sub(before), receipt };
  };
  const refSell = async (signer, amount) => {
    const before = await rUsdc.balanceOf(signer.address);
    const tx = await rRouter.connect(signer).sell(rCoin.address, amount, 0, 0);
    const receipt = await tx.wait();
    return { out: (await rUsdc.balanceOf(signer.address)).sub(before), receipt };
  };

  before(async function () {
    [owner, treasury, creator, alice, bob] = await ethers.getSigners();
    const users = [creator, alice, bob];

    // ---------- v4 side ----------
    pm = await (await ethers.getContractFactory("PoolManager")).deploy(owner.address);
    quote = await (await ethers.getContractFactory("SpikeQuote")).deploy();
    const Hook = await ethers.getContractFactory("WavefrontHook");
    const impl = await Hook.deploy(pm.address, quote.address, TICK_SPACING);
    await impl.deployed();
    // v4 reads hook permissions from the address bits, so place the code at a flagged address.
    await network.provider.send("hardhat_setCode", [HOOK_ADDRESS, await ethers.provider.getCode(impl.address)]);
    hook = Hook.attach(HOOK_ADDRESS);
    await hook.setTreasury(treasury.address);
    router = await (await ethers.getContractFactory("SpikeRouter")).deploy(pm.address);

    for (const u of users) {
      await quote.mint(u.address, usdc(1_000_000));
      await quote.connect(u).approve(router.address, ethers.constants.MaxUint256);
      await quote.connect(u).approve(hook.address, ethers.constants.MaxUint256);
    }

    // coin must sort below quote so it is currency0 — production would mine the CREATE2 salt
    let salt;
    for (let i = 0; i < 200; i++) {
      salt = ethers.utils.hexZeroPad(ethers.utils.hexlify(i), 32);
      try {
        await hook.connect(creator).callStatic.launch(salt);
        break;
      } catch (e) {
        salt = null;
      }
    }
    expect(salt, "no salt sorted the coin below the quote").to.not.equal(null);
    const coinAddr = await hook.connect(creator).callStatic.launch(salt);
    gas.launch = { v4: (await (await hook.connect(creator).launch(salt)).wait()).gasUsed.toNumber() };
    coin = (await ethers.getContractFactory("SpikeCoin")).attach(coinAddr);
    const m = await hook.market(coin.address);
    key = [m.key.currency0, m.key.currency1, m.key.fee, m.key.tickSpacing, m.key.hooks];
    for (const u of users) await coin.connect(u).approve(router.address, ethers.constants.MaxUint256);

    // ---------- reference side (current wavefront contracts) ----------
    const F = (file, name) => {
      const a = refArtifact(file, name);
      return new ethers.ContractFactory(a.abi, a.bytecode, owner);
    };
    rUsdc = await F("mocks/USDC.sol", "USDC").deploy();
    rCore = await F("Core.sol", "Core").deploy(rUsdc.address);
    rRouter = await F("Router.sol", "Router").deploy(rCore.address);
    await rCore.setTreasury(treasury.address);
    for (const u of users) {
      await rUsdc.mint(u.address, usdc(1_000_000));
      await rUsdc.connect(u).approve(rRouter.address, ethers.constants.MaxUint256);
    }
  });

  after(function () {
    console.log("\n  Parity: v4 hook vs current Coin.sol");
    console.table(rows);
    console.log("  Gas used");
    console.table(gas);
  });

  it("launch: whole supply sits in one single-sided v4 position at the floor", async function () {
    const s = await v4State();
    expect(s.price).to.equal(s.floor);
    expect(big(await quote.balanceOf(pm.address))).to.equal(0n);
    // 1e14 = 100,000 USDC virtual / 1B coins, the launch floor of the current contracts
    expect(record("launch: floor price", s.floor, 10n ** 14n)).to.be.lt(TOL);
    expect(rel(await coin.balanceOf(pm.address), ethers.utils.parseEther("1000000000"))).to.be.lt(1e-9);
    // nobody else may create a pool on this hook
    await expect(pm.initialize([key[0], key[1], 3000, 60, key[4]], "79228162514264337593543950336")).to.be.reverted;
    // and nobody else may add liquidity to it
    const probe = await (await ethers.getContractFactory("LiquidityProbe")).deploy(pm.address);
    const lower = s.m.floorTick;
    await expect(probe.tryAdd(key, lower, lower + TICK_SPACING * 10)).to.be.reverted;
  });

  it("first buy (creation buy) matches Coin.sol", async function () {
    const amount = usdc(1000);
    const tx = await rRouter.connect(creator).createCoin("Wave", "WAVE", amount);
    const rc = await tx.wait();
    gas.createCoin = { reference: rc.gasUsed.toNumber() };
    const created = rc.events.find((e) => e.event === "Router__CoinCreated");
    const a = refArtifact("Coin.sol", "Coin");
    rCoin = new ethers.Contract(created.args.coin, a.abi, owner);
    for (const u of [creator, alice, bob]) {
      await rCoin.connect(u).approve(rRouter.address, ethers.constants.MaxUint256);
      await rUsdc.connect(u).approve(rCoin.address, ethers.constants.MaxUint256);
    }

    const v = await v4Buy(creator, amount);
    gas.buy = { v4: v.receipt.gasUsed.toNumber() };
    // reference mints to Core, which keeps 1 coin and forwards the rest
    const refOut = await rCoin.totalSupply();
    expect(record("buy 1,000: coins out", v.out, refOut)).to.be.lt(TOL);
    await compareState("after buy 1,000");
  });

  it("a buy is an ordinary PoolManager Swap with real amounts", async function () {
    const before = await quote.balanceOf(creator.address);
    const amount = usdc(5000);
    const v = await v4Buy(alice, amount);
    const r = await refBuy(alice, amount);
    gas.buy.reference = r.receipt.gasUsed.toNumber();
    gas.buy.v4 = v.receipt.gasUsed.toNumber();

    const logs = v.receipt.logs.filter((l) => l.address === pm.address).map((l) => pm.interface.parseLog(l));
    const swaps = logs.filter((l) => l.name === "Swap");
    const mods = logs.filter((l) => l.name === "ModifyLiquidity");
    // first Swap is the trade itself: coin out (amount0 > 0 to the swapper), quote in (amount1 < 0)
    expect(swaps[0].args.amount1.abs()).to.equal(amount);
    expect(swaps[0].args.amount0).to.equal(v.out);
    expect(swaps[0].args.liquidity).to.be.gt(0);
    // second Swap is the zero-amount price nudge of the ratchet
    expect(swaps.length).to.equal(2);
    expect(swaps[1].args.amount0).to.equal(0);
    expect(swaps[1].args.amount1).to.equal(0);
    expect(mods.length).to.equal(2);
    rows.push({ check: "events per trade", v4: `${swaps.length} Swap + ${mods.length} ModifyLiquidity`, reference: "-", diff: "-" });

    expect(record("buy 5,000: coins out", v.out, r.out)).to.be.lt(TOL);
    // team gets 20% of the 2% fee: 4 USDC from the creation buy + 20 USDC from this one
    expect(await hook.feesOwed(creator.address)).to.be.gt(0);
    await hook.claimFees(creator.address);
    const paid = (await quote.balanceOf(creator.address)).sub(before);
    expect(record("team fee after two buys", paid, usdc(24))).to.be.lt(1e-5);
    await compareState("after buy 5,000");
  });

  it("sells match, including the supply burn", async function () {
    const amount = (await coin.balanceOf(alice.address)).mul(40).div(100);
    const v = await v4Sell(alice, amount);
    const r = await refSell(alice, amount);
    gas.sell = { v4: v.receipt.gasUsed.toNumber(), reference: r.receipt.gasUsed.toNumber() };
    expect(record("sell 40%: quote out", v.out, r.out)).to.be.lt(TOL);
    await compareState("after sell");
  });

  it("a larger buy keeps parity after several ratchets", async function () {
    const amount = usdc(50_000);
    const v = await v4Buy(bob, amount);
    const r = await refBuy(bob, amount);
    expect(record("buy 50,000: coins out", v.out, r.out)).to.be.lt(TOL);
    await compareState("after buy 50,000");
  });

  it("borrowing: credit matches, quote comes out of the v4 position, collateral locks", async function () {
    const credit = await hook.creditOf(coin.address, alice.address);
    const refCredit = await rCoin.getAccountCredit(alice.address);
    expect(record("alice credit", credit, refCredit)).to.be.lt(TOL * 2);

    const pmBefore = await quote.balanceOf(pm.address);
    const before = await quote.balanceOf(alice.address);
    const m0 = (await v4State()).m;

    const b = await borrowMax(alice);
    const amount = b.amount;
    gas.borrow = { v4: b.receipt.gasUsed.toNumber() };
    rows.push({ check: "borrow: usable share of Coin.sol credit", v4: (b.bps / 100).toFixed(1) + "%", reference: "100%", diff: "-" });
    gas.borrow.reference = (await (await rCoin.connect(alice).borrow(alice.address, amount)).wait()).gasUsed.toNumber();

    expect((await quote.balanceOf(alice.address)).sub(before)).to.equal(amount);
    const m1 = (await v4State()).m;
    // the quote physically left the PoolManager: the position's lower tick moved up, price did not move
    expect(m1.lowerTick).to.be.gt(m0.lowerTick);
    expect(m1.sqrtPriceX96).to.equal(m0.sqrtPriceX96);
    expect(pmBefore.sub(await quote.balanceOf(pm.address))).to.equal(amount);
    rows.push({
      check: "borrow: lower tick moved",
      v4: `${m0.lowerTick} -> ${m1.lowerTick}`,
      reference: "-",
      diff: "-",
    });
    rows.push({ check: "borrow: idle quote left in hook (USDC)", v4: fmtUsd(m1.idleQuote), reference: "-", diff: "-" });

    // locked collateral agrees with Coin.sol
    const bal = await coin.balanceOf(alice.address);
    const locked = await hook.lockedOf(coin.address, alice.address);
    const refBal = await rCoin.balanceOf(alice.address);
    const refLocked = refBal.sub(await rCoin.getAccountTransferrable(alice.address));
    // v4 locks slightly more: the debt boundary is rounded up to a tick, and that slack stays locked
    record("alice locked coins", locked, refLocked);
    expect(locked).to.be.gte(refLocked.mul(9999).div(10000));
    expect(locked).to.be.lte(bal);

    await expect(coin.connect(alice).transfer(bob.address, bal)).to.be.reverted;
    await expect(router.connect(alice).swapExactIn(key, true, bal, "0x")).to.be.reverted;
    // cannot borrow past the limit
    await expect(hook.connect(alice).borrow(coin.address, credit.div(4), alice.address)).to.be.reverted;
    // the unlocked remainder still moves
    // (same amount on both sides so the two runs stay comparable; v4's free amount is the smaller one)
    const free = bal.sub(locked).mul(999).div(1000);
    await coin.connect(alice).transfer(bob.address, free);
    await rCoin.connect(alice).transfer(bob.address, free);
  });

  it("solvency: everyone else can exit while the loan is out, then the loan unwinds", async function () {
    // every non-borrower sells everything they hold
    for (const who of [bob, creator, treasury]) {
      // coin fees are pull-based on v4 (Coin.sol mints them straight to the recipient)
      await hook.claimCoinFees(coin.address, who.address);
      const v4Bal = await coin.balanceOf(who.address);
      if (v4Bal.gt(1000)) {
        await coin.connect(who).approve(router.address, ethers.constants.MaxUint256);
        await v4Sell(who, v4Bal);
      }
      const refBal = await rCoin.balanceOf(who.address);
      if (refBal.gt(1000)) {
        await rCoin.connect(who).approve(rRouter.address, ethers.constants.MaxUint256);
        await refSell(who, refBal);
      }
    }
    const s = await v4State();
    // price never fell into the range whose quote was lent out
    expect(big(s.m.sqrtPriceX96) >= big(s.m.floorSqrtX96)).to.equal(true);
    await compareState("after others exit");

    // repay in full, on both
    const debt = await hook.debtOf(coin.address, alice.address);
    const tx = await hook.connect(alice).repay(coin.address, debt, alice.address);
    gas.repay = { v4: (await tx.wait()).gasUsed.toNumber() };
    gas.repay.reference = (await (await rCoin.connect(alice).repay(alice.address, debt)).wait()).gasUsed.toNumber();
    const m = (await v4State()).m;
    expect(m.totalDebt).to.equal(0);
    expect(m.lowerTick).to.equal(m.floorTick);
    expect(await hook.lockedOf(coin.address, alice.address)).to.equal(0);

    // and the borrower can now sell everything
    const v = await v4Sell(alice, await coin.balanceOf(alice.address));
    const r = await refSell(alice, await rCoin.balanceOf(alice.address));
    expect(record("alice final sell: quote out", v.out, r.out)).to.be.lt(TOL * 2);
    await compareState("final");

    const end = (await v4State()).m;
    rows.push({ check: "final: idle quote in hook (USDC)", v4: fmtUsd(end.idleQuote), reference: "-", diff: "-" });
    // Quote the PoolManager holds for this pool = position + idle + unclaimed fees.
    let unclaimed = ethers.BigNumber.from(0);
    for (const who of [creator, treasury]) unclaimed = unclaimed.add(await hook.feesOwed(who.address));
    const backing = (await quote.balanceOf(pm.address)).sub(unclaimed);
    expect(record("final: quote backing the curve (raw)", backing, await rUsdc.balanceOf(rCoin.address))).to.be.lt(0.2);
    rows.push({ check: "final: unclaimed fees held as claims (USDC)", v4: fmtUsd(unclaimed), reference: "-", diff: "-" });
  });

  it("two borrowers at once: third parties trade through, both unwind", async function () {
    await v4Buy(bob, usdc(10_000));
    await v4Buy(creator, usdc(20_000));
    for (const who of [bob, creator]) await borrowMax(who);
    const before = await v4State();
    expect(before.m.lowerTick).to.be.gt(before.m.floorTick);

    // a third party buys and fully exits while both loans are out
    await v4Buy(alice, usdc(5_000));
    await v4Sell(alice, await coin.balanceOf(alice.address));
    // borrowers dump everything that is not locked
    for (const who of [bob, creator]) {
      const free = (await coin.balanceOf(who.address)).sub(await hook.lockedOf(coin.address, who.address));
      // the lock moves by up to a tick-spacing of coin as the ratchet re-ranges, so leave that slack
      const keep = TICK_SPACING <= 10 ? 999 : 900;
      if (free.gt(ethers.utils.parseEther("1"))) await v4Sell(who, free.mul(keep).div(1000));
    }
    // the pool is still live and the lent range was never reached
    const mid = await v4State();
    expect(mid.m.liquidity).to.be.gt(0);
    expect(mid.price >= mid.floor).to.equal(true);

    for (const who of [bob, creator]) {
      await hook.connect(who).repay(coin.address, await hook.debtOf(coin.address, who.address), who.address);
      await v4Sell(who, await coin.balanceOf(who.address));
    }
    const end = await v4State();
    expect(end.m.totalDebt).to.equal(0);
    expect(end.m.lowerTick).to.equal(end.m.floorTick);
    expect(end.floor > before.floor).to.equal(true);
    rows.push({ check: "two borrowers: idle quote in hook after unwind (USDC)", v4: fmtUsd(end.m.idleQuote), reference: "-", diff: "-" });
  });

  it("gas vs size of the price move (the only non-constant cost is v4's own tick walk)", async function () {
    rows.push({ check: "largest swap gas in the scenarios above", v4: String(maxSwapGas), reference: "-", diff: "-" });
    await quote.mint(bob.address, usdc(20_000_000));
    for (const size of [1_000, 100_000, 1_000_000, 10_000_000]) {
      const p0 = (await v4State()).price;
      const v = await v4Buy(bob, usdc(size));
      const p1 = (await v4State()).price;
      const multiple = Number((p1 * 1000n) / p0) / 1000;
      gas[`buy ${size.toLocaleString()} (price x${multiple})`] = { v4: v.receipt.gasUsed.toNumber() };
    }
    // and one sell of everything bob holds, back down the curve
    const p0 = (await v4State()).price;
    const v = await v4Sell(bob, await coin.balanceOf(bob.address));
    const p1 = (await v4State()).price;
    gas[`sell all (price /${(Number((p0 * 1000n) / p1) / 1000).toFixed(1)})`] = { v4: v.receipt.gasUsed.toNumber() };
  });
});
