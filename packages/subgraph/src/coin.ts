import { Address, BigDecimal, BigInt } from "@graphprotocol/graph-ts";
import {
  Coin__Borrow,
  Coin__Burn,
  Coin__BurnReserves,
  Coin__Heal,
  Coin__HealReserves,
  Coin__ProviderFee,
  Coin__Repay,
  Coin__Swap,
  Coin__SyncReserves,
  Coin__TeamFee,
  Coin__TeamSet,
  Coin__TreasuryFee,
  Transfer,
} from "../generated/templates/Coin/Coin";
import {
  Coin,
  CoinDayData,
  CoinHourData,
  CoinMinuteData,
  CoinPosition,
  Directory,
  Swap,
  User,
} from "../generated/schema";
import {
  ALMOST_ZERO_BD,
  BI_18,
  BI_6,
  DIRECTORY_ID,
  ONE_BI,
  ZERO_BD,
  ZERO_BI,
} from "./constants";
import { convertTokenToDecimal } from "./helpers";

function loadOrCreateUser(id: string): User {
  let user = User.load(id);
  if (user == null) {
    user = new User(id);
    user.txCount = ZERO_BI;
  }
  return user;
}

function loadOrCreatePosition(coinAddress: Address, userAddress: Address): CoinPosition {
  let id = coinAddress.toHexString() + "-" + userAddress.toHexString();
  let position = CoinPosition.load(id);
  if (position == null) {
    position = new CoinPosition(id);
    position.coin = coinAddress.toHexString();
    position.user = userAddress.toHexString();
    position.balance = ZERO_BD;
    position.debt = ZERO_BD;
    position.affiliateRevenueQuote = ZERO_BD;
    position.affiliateRevenueCoin = ZERO_BD;
  }
  return position;
}

function recomputePrices(coin: Coin): void {
  let reserveQuote = coin.quoteVirtReserve.plus(coin.quoteRealReserve);
  if (coin.totalSupply.gt(ZERO_BD)) {
    coin.floorPrice = coin.quoteVirtReserve.div(coin.totalSupply);
  }
  if (coin.coinReserve.gt(ZERO_BD)) {
    coin.marketPrice = reserveQuote.div(coin.coinReserve);
  }
  coin.marketCap = coin.marketPrice.times(coin.totalSupply);
  let initialLiquidity = coin.liquidity;
  coin.liquidity = reserveQuote.times(BigDecimal.fromString("2"));

  let directory = Directory.load(DIRECTORY_ID);
  if (directory != null) {
    directory.liquidity = directory.liquidity.minus(initialLiquidity).plus(coin.liquidity);
    directory.save();
  }
}

export function handleCoin__Swap(event: Coin__Swap): void {
  let directory = Directory.load(DIRECTORY_ID)!;
  directory.txCount = directory.txCount.plus(ONE_BI);
  directory.swapVolume = directory.swapVolume
    .plus(convertTokenToDecimal(event.params.quoteInRaw, BI_6))
    .plus(convertTokenToDecimal(event.params.quoteOutRaw, BI_6));
  directory.save();

  let userFrom = loadOrCreateUser(event.params.from.toHexString());
  userFrom.txCount = userFrom.txCount.plus(ONE_BI);
  userFrom.save();

  let userTo = loadOrCreateUser(event.params.to.toHexString());
  userTo.save();

  let coin = Coin.load(event.address.toHexString())!;
  coin.txCount = coin.txCount.plus(ONE_BI);
  coin.swapVolume = coin.swapVolume
    .plus(convertTokenToDecimal(event.params.quoteInRaw, BI_6))
    .plus(convertTokenToDecimal(event.params.quoteOutRaw, BI_6));
  coin.save();

  let swap = new Swap(event.transaction.hash.toHexString());
  swap.coin = coin.id;
  swap.user = userFrom.id;
  swap.blockNumber = event.block.number;
  swap.timestamp = event.block.timestamp;
  swap.quoteIn = convertTokenToDecimal(event.params.quoteInRaw, BI_6);
  swap.quoteOut = convertTokenToDecimal(event.params.quoteOutRaw, BI_6);
  swap.coinIn = convertTokenToDecimal(event.params.coinIn, BI_18);
  swap.coinOut = convertTokenToDecimal(event.params.coinOut, BI_18);
  swap.marketPrice = coin.marketPrice;
  swap.floorPrice = coin.floorPrice;
  swap.save();

  let timestamp = event.block.timestamp.toI32();
  let volume = swap.quoteIn.plus(swap.quoteOut);

  let dayIndex = timestamp / 86400;
  let dayId = coin.id + "-" + dayIndex.toString();
  let dayData = CoinDayData.load(dayId);
  if (dayData == null) {
    dayData = new CoinDayData(dayId);
    dayData.coin = coin.id;
    dayData.timestamp = BigInt.fromI32(dayIndex * 86400);
    dayData.volume = ZERO_BD;
  }
  dayData.marketPrice = coin.marketPrice;
  dayData.floorPrice = coin.floorPrice;
  dayData.volume = dayData.volume.plus(volume);
  dayData.save();

  let hourIndex = timestamp / 3600;
  let hourId = coin.id + "-" + hourIndex.toString();
  let hourData = CoinHourData.load(hourId);
  if (hourData == null) {
    hourData = new CoinHourData(hourId);
    hourData.coin = coin.id;
    hourData.timestamp = BigInt.fromI32(hourIndex * 3600);
    hourData.volume = ZERO_BD;
  }
  hourData.marketPrice = coin.marketPrice;
  hourData.floorPrice = coin.floorPrice;
  hourData.volume = hourData.volume.plus(volume);
  hourData.save();

  let minuteIndex = timestamp / 60;
  let minuteId = coin.id + "-" + minuteIndex.toString();
  let minuteData = CoinMinuteData.load(minuteId);
  if (minuteData == null) {
    minuteData = new CoinMinuteData(minuteId);
    minuteData.coin = coin.id;
    minuteData.timestamp = BigInt.fromI32(minuteIndex * 60);
    minuteData.volume = ZERO_BD;
  }
  minuteData.marketPrice = coin.marketPrice;
  minuteData.floorPrice = coin.floorPrice;
  minuteData.volume = minuteData.volume.plus(volume);
  minuteData.save();
}

export function handleCoin__SyncReserves(event: Coin__SyncReserves): void {
  let coin = Coin.load(event.address.toHexString())!;
  coin.quoteRealReserve = convertTokenToDecimal(event.params.reserveRealQuoteWad, BI_18);
  coin.quoteVirtReserve = convertTokenToDecimal(event.params.reserveVirtQuoteWad, BI_18);
  coin.coinReserve = convertTokenToDecimal(event.params.reserveCoinAmt, BI_18);
  recomputePrices(coin);
  coin.save();
}

export function handleCoin__HealReserves(event: Coin__HealReserves): void {
  let coin = Coin.load(event.address.toHexString())!;
  coin.holderRevenueQuote = coin.holderRevenueQuote.plus(
    convertTokenToDecimal(event.params.quoteWad, BI_18)
  );
  coin.save();
}

export function handleCoin__BurnReserves(event: Coin__BurnReserves): void {
  let coin = Coin.load(event.address.toHexString())!;
  coin.totalSupply = coin.totalSupply.minus(
    convertTokenToDecimal(event.params.reserveBurn, BI_18)
  );
  coin.holderRevenueCoin = coin.holderRevenueCoin.plus(
    convertTokenToDecimal(event.params.coinAmt, BI_18)
  );
  coin.save();
}

export function handleCoin__ProviderFee(event: Coin__ProviderFee): void {
  let user = loadOrCreateUser(event.params.to.toHexString());
  user.save();

  let position = loadOrCreatePosition(event.address, event.params.to);
  position.affiliateRevenueQuote = position.affiliateRevenueQuote.plus(
    convertTokenToDecimal(event.params.quoteRaw, BI_6)
  );
  position.affiliateRevenueCoin = position.affiliateRevenueCoin.plus(
    convertTokenToDecimal(event.params.coinAmt, BI_18)
  );
  position.save();
}

export function handleCoin__TeamFee(event: Coin__TeamFee): void {
  let coin = Coin.load(event.address.toHexString())!;
  coin.teamRevenueQuote = coin.teamRevenueQuote.plus(
    convertTokenToDecimal(event.params.quoteRaw, BI_6)
  );
  coin.teamRevenueCoin = coin.teamRevenueCoin.plus(
    convertTokenToDecimal(event.params.coinAmt, BI_18)
  );
  coin.save();
}

export function handleCoin__TreasuryFee(event: Coin__TreasuryFee): void {
  let coin = Coin.load(event.address.toHexString())!;
  coin.treasuryRevenueQuote = coin.treasuryRevenueQuote.plus(
    convertTokenToDecimal(event.params.quoteRaw, BI_6)
  );
  coin.treasuryRevenueCoin = coin.treasuryRevenueCoin.plus(
    convertTokenToDecimal(event.params.coinAmt, BI_18)
  );
  coin.save();
}

export function handleCoin__Heal(event: Coin__Heal): void {}

export function handleCoin__Burn(event: Coin__Burn): void {}

export function handleCoin__Borrow(event: Coin__Borrow): void {
  let userWho = loadOrCreateUser(event.params.who.toHexString());
  userWho.txCount = userWho.txCount.plus(ONE_BI);
  userWho.save();

  let userTo = loadOrCreateUser(event.params.to.toHexString());
  userTo.save();

  let position = loadOrCreatePosition(event.address, event.params.who);
  position.debt = position.debt.plus(
    convertTokenToDecimal(event.params.quoteRaw, BI_6)
  );
  position.save();

  let directory = Directory.load(DIRECTORY_ID)!;
  directory.txCount = directory.txCount.plus(ONE_BI);
  directory.save();

  let coin = Coin.load(event.address.toHexString())!;
  coin.txCount = coin.txCount.plus(ONE_BI);
  coin.save();
}

export function handleCoin__Repay(event: Coin__Repay): void {
  let userWho = loadOrCreateUser(event.params.who.toHexString());
  userWho.txCount = userWho.txCount.plus(ONE_BI);
  userWho.save();

  let userTo = loadOrCreateUser(event.params.to.toHexString());
  userTo.save();

  let position = loadOrCreatePosition(event.address, event.params.to);
  position.debt = position.debt.minus(
    convertTokenToDecimal(event.params.quoteRaw, BI_6)
  );
  position.save();

  let directory = Directory.load(DIRECTORY_ID)!;
  directory.txCount = directory.txCount.plus(ONE_BI);
  directory.save();

  let coin = Coin.load(event.address.toHexString())!;
  coin.txCount = coin.txCount.plus(ONE_BI);
  coin.save();
}

export function handleCoin__TeamSet(event: Coin__TeamSet): void {
  let user = loadOrCreateUser(event.params.newTeam.toHexString());
  user.save();

  let coin = Coin.load(event.address.toHexString())!;
  coin.team = user.id;
  coin.save();
}

export function handleTransfer(event: Transfer): void {
  let coin = Coin.load(event.address.toHexString())!;

  let userFrom = loadOrCreateUser(event.params.from.toHexString());
  userFrom.save();

  let userTo = loadOrCreateUser(event.params.to.toHexString());
  userTo.save();

  let value = convertTokenToDecimal(event.params.value, BI_18);

  let fromPosition = loadOrCreatePosition(event.address, event.params.from);
  let fromInitial = fromPosition.balance;
  fromPosition.balance = fromInitial.minus(value);
  if (
    fromInitial.gt(ALMOST_ZERO_BD) &&
    fromPosition.balance.lt(ALMOST_ZERO_BD)
  ) {
    coin.holders = coin.holders.minus(ONE_BI);
  }
  fromPosition.save();

  let toPosition = loadOrCreatePosition(event.address, event.params.to);
  let toInitial = toPosition.balance;
  toPosition.balance = toInitial.plus(value);
  if (toInitial.lt(ALMOST_ZERO_BD) && toPosition.balance.gt(ALMOST_ZERO_BD)) {
    coin.holders = coin.holders.plus(ONE_BI);
  }
  toPosition.save();

  coin.save();
}
