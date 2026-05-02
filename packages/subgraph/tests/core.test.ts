import { Address, BigInt, ethereum } from "@graphprotocol/graph-ts";
import { assert, clearStore, describe, newMockEvent, test } from "matchstick-as/assembly/index";
import { handleCore__CoinCreated } from "../src/core";
import { Core__CoinCreated } from "../generated/Core/Core";
import { DIRECTORY_ID } from "../src/constants";

const CORE_ADDR = Address.fromString("0x0000000000000000000000000000000000000001");
const COIN_ADDR = Address.fromString("0x000000000000000000000000000000000000c01a");
const OWNER_ADDR = Address.fromString("0x00000000000000000000000000000000000000ee");

function buildCoinCreatedEvent(): Core__CoinCreated {
  let mock = newMockEvent();
  mock.address = CORE_ADDR;
  let event = new Core__CoinCreated(
    mock.address,
    mock.logIndex,
    mock.transactionLogIndex,
    mock.logType,
    mock.block,
    mock.transaction,
    mock.parameters,
    mock.receipt
  );
  event.parameters = new Array();
  event.parameters.push(new ethereum.EventParam("name", ethereum.Value.fromString("Wave Coin")));
  event.parameters.push(new ethereum.EventParam("symbol", ethereum.Value.fromString("WAVE")));
  event.parameters.push(
    new ethereum.EventParam("index", ethereum.Value.fromUnsignedBigInt(BigInt.fromI32(1)))
  );
  event.parameters.push(new ethereum.EventParam("coin", ethereum.Value.fromAddress(COIN_ADDR)));
  event.parameters.push(new ethereum.EventParam("owner", ethereum.Value.fromAddress(OWNER_ADDR)));
  return event;
}

describe("handleCore__CoinCreated", () => {
  test("creates Directory, User, Coin, and CoinPosition entities", () => {
    clearStore();
    handleCore__CoinCreated(buildCoinCreatedEvent());

    assert.fieldEquals("Directory", DIRECTORY_ID, "index", "1");
    assert.fieldEquals("Directory", DIRECTORY_ID, "txCount", "1");

    let coinId = COIN_ADDR.toHexString();
    let ownerId = OWNER_ADDR.toHexString();
    assert.fieldEquals("Coin", coinId, "name", "Wave Coin");
    assert.fieldEquals("Coin", coinId, "symbol", "WAVE");
    assert.fieldEquals("Coin", coinId, "owner", ownerId);
    assert.fieldEquals("Coin", coinId, "team", ownerId);
    assert.fieldEquals("Coin", coinId, "txCount", "1");

    assert.fieldEquals("User", ownerId, "txCount", "0");

    let positionId = coinId + "-" + ownerId;
    assert.fieldEquals("CoinPosition", positionId, "balance", "0");
    assert.fieldEquals("CoinPosition", positionId, "debt", "0");
  });
});
