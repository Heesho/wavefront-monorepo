#!/usr/bin/env node
const fs = require("fs");
const path = require("path");

const ARTIFACT_DIR = path.join(__dirname, "..", "packages", "hardhat", "artifacts", "contracts");
const ABI_DIR = path.join(__dirname, "..", "packages", "subgraph", "abis");

const TARGETS = [
  { artifact: "Coin.sol/Coin.json", abi: "Coin.json" },
  { artifact: "Core.sol/Core.json", abi: "Core.json" },
];

if (!fs.existsSync(ABI_DIR)) {
  fs.mkdirSync(ABI_DIR, { recursive: true });
}

let synced = 0;
for (const target of TARGETS) {
  const src = path.join(ARTIFACT_DIR, target.artifact);
  if (!fs.existsSync(src)) {
    console.error(`✖ missing artifact: ${src}`);
    console.error(`  Run \`yarn compile\` first.`);
    process.exit(1);
  }
  const json = JSON.parse(fs.readFileSync(src, "utf8"));
  const out = path.join(ABI_DIR, target.abi);
  fs.writeFileSync(out, JSON.stringify(json.abi, null, 2));
  console.log(`✓ ${target.abi}`);
  synced++;
}

console.log(`Synced ${synced} ABIs to ${ABI_DIR}.`);
