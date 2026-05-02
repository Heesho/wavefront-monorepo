import { Coin as CoinTemplate } from "../generated/templates";
import {
  Core__CoinCreated,
  Core__TreasurySet,
} from "../generated/Core/Core";
import { Coin, CoinPosition, Directory, User } from "../generated/schema";
import {
  DIRECTORY_ID,
  INITIAL_COIN_RESERVE,
  INITIAL_LIQUIDITY,
  INITIAL_MARKET_CAP,
  INITIAL_PRICE,
  INITIAL_QUOTE_VIRT_RESERVE,
  INITIAL_TOTAL_SUPPLY,
  ONE_BI,
  ZERO_BD,
  ZERO_BI,
} from "./constants";

function loadOrCreateUser(id: string): User {
  let user = User.load(id);
  if (user == null) {
    user = new User(id);
    user.txCount = ZERO_BI;
  }
  return user;
}

function loadOrCreateDirectory(): Directory {
  let directory = Directory.load(DIRECTORY_ID);
  if (directory == null) {
    directory = new Directory(DIRECTORY_ID);
    directory.index = ZERO_BI;
    directory.txCount = ZERO_BI;
    directory.swapVolume = ZERO_BD;
    directory.liquidity = ZERO_BD;
  }
  return directory;
}

export function handleCore__CoinCreated(event: Core__CoinCreated): void {
  let directory = loadOrCreateDirectory();
  directory.index = directory.index.plus(ONE_BI);
  directory.txCount = directory.txCount.plus(ONE_BI);
  directory.liquidity = directory.liquidity.plus(INITIAL_LIQUIDITY);
  directory.save();

  let owner = loadOrCreateUser(event.params.owner.toHexString());
  owner.save();

  CoinTemplate.create(event.params.coin);

  let coin = Coin.load(event.params.coin.toHexString());
  if (coin == null) {
    coin = new Coin(event.params.coin.toHexString());
    coin.name = event.params.name;
    coin.symbol = event.params.symbol;
    coin.owner = owner.id;
    coin.team = owner.id;

    coin.txCount = ZERO_BI;
    coin.swapVolume = ZERO_BD;
    coin.liquidity = INITIAL_LIQUIDITY;
    coin.totalSupply = INITIAL_TOTAL_SUPPLY;
    coin.marketCap = INITIAL_MARKET_CAP;
    coin.quoteVirtReserve = INITIAL_QUOTE_VIRT_RESERVE;
    coin.quoteRealReserve = ZERO_BD;
    coin.coinReserve = INITIAL_COIN_RESERVE;
    coin.marketPrice = INITIAL_PRICE;
    coin.floorPrice = INITIAL_PRICE;
    coin.holders = ZERO_BI;

    coin.holderRevenueQuote = ZERO_BD;
    coin.holderRevenueCoin = ZERO_BD;
    coin.teamRevenueQuote = ZERO_BD;
    coin.teamRevenueCoin = ZERO_BD;
    coin.treasuryRevenueQuote = ZERO_BD;
    coin.treasuryRevenueCoin = ZERO_BD;

    coin.createdAtTimestamp = event.block.timestamp;
    coin.createdAtBlockNumber = event.block.number;
  }
  coin.txCount = coin.txCount.plus(ONE_BI);
  coin.save();

  let positionId =
    event.params.coin.toHexString() + "-" + event.params.owner.toHexString();
  let position = CoinPosition.load(positionId);
  if (position == null) {
    position = new CoinPosition(positionId);
    position.coin = coin.id;
    position.user = owner.id;
    position.balance = ZERO_BD;
    position.debt = ZERO_BD;
    position.affiliateRevenueQuote = ZERO_BD;
    position.affiliateRevenueCoin = ZERO_BD;
  }
  position.save();
}

export function handleCore__TreasurySet(event: Core__TreasurySet): void {}
