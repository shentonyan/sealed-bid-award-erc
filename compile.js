// Compile-check all contracts with solc-js and report errors/warnings.
const solc = require("solc");
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "src");
const sources = {};
function walk(dir) {
  for (const f of fs.readdirSync(dir)) {
    const p = path.join(dir, f);
    if (fs.statSync(p).isDirectory()) walk(p);
    else if (p.endsWith(".sol")) sources[path.relative(root, p)] = { content: fs.readFileSync(p, "utf8") };
  }
}
walk(root);

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object"] } },
  },
};
function findImports(p) {
  const key = Object.keys(sources).find((k) => k.endsWith(p.replace(/^\.\//, "")) || k === p);
  return key ? { contents: sources[key].content } : { error: "not found: " + p };
}
const out = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
let bad = false;
for (const e of out.errors || []) {
  console.log(`${e.severity}: ${e.formattedMessage}`);
  if (e.severity === "error") bad = true;
}
if (bad) process.exit(1);
for (const [file, cs] of Object.entries(out.contracts)) {
  for (const [name, c] of Object.entries(cs)) {
    const size = c.evm.deployedBytecode.object.length / 2;
    if (size > 0) console.log(`${name.padEnd(22)} ${size} bytes deployed`);
  }
}
fs.writeFileSync(path.join(__dirname, "build.json"), JSON.stringify(out.contracts));
console.log("ok");
