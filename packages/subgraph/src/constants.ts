import { BigDecimal, BigInt } from "@graphprotocol/graph-ts/index";

export const ADDRESS_ZERO = "0x0000000000000000000000000000000000000000";
export const DIRECTORY_ID = "wavefront";

export const ZERO_BI = BigInt.fromI32(0);
export const ONE_BI = BigInt.fromI32(1);
export const ZERO_BD = BigDecimal.fromString("0");
export const ONE_BD = BigDecimal.fromString("1");
export const BI_18 = BigInt.fromI32(18);
export const BI_6 = BigInt.fromI32(6);

export const ALMOST_ZERO_BD = BigDecimal.fromString("0.000001");

export const INITIAL_LIQUIDITY = BigDecimal.fromString("200000");
export const INITIAL_MARKET_CAP = BigDecimal.fromString("100000");
export const INITIAL_PRICE = BigDecimal.fromString("0.0001");
export const INITIAL_TOTAL_SUPPLY = BigDecimal.fromString("1000000000");
export const INITIAL_COIN_RESERVE = BigDecimal.fromString("1000000000");
export const INITIAL_QUOTE_VIRT_RESERVE = BigDecimal.fromString("100000");
