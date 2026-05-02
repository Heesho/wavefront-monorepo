const fs = require("fs");
const path = require("path");

const network = process.argv[2];
if (!network) {
  console.error("Please provide a network name (localhost, base-sepolia, base)");
  process.exit(1);
}

const networksPath = path.join(__dirname, "networks.json");
const templatePath = path.join(__dirname, "subgraph.template.yaml");
const outputPath = path.join(__dirname, "subgraph.yaml");

const networks = JSON.parse(fs.readFileSync(networksPath, "utf8"));
const config = networks[network];

if (!config) {
  console.error(`Network ${network} not found in networks.json`);
  process.exit(1);
}

let template = fs.readFileSync(templatePath, "utf8");

template = template.replace(/{{network}}/g, network);

if (config.Core) {
  template = template.replace(/{{Core.address}}/g, config.Core.address);
  template = template.replace(/{{Core.startBlock}}/g, String(config.Core.startBlock));
}

fs.writeFileSync(outputPath, template);
console.log(`Generated subgraph.yaml for ${network}`);
