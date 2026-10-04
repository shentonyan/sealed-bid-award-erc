// In-process EVM harness: deploys the compiled contracts and drives them with raw calls.
// This is the same coverage the Foundry suite gives, runnable without Foundry.
const { createVM } = require("@ethereumjs/vm");
const { Common, Mainnet, Hardfork } = require("@ethereumjs/common");
const util = require("@ethereumjs/util");
const { Interface, AbiCoder, keccak256, hexlify, randomBytes } = require("ethers");
const build = require("../build.json");

const coder = AbiCoder.defaultAbiCoder();
const hex = (b) => "0x" + Buffer.from(b).toString("hex");
const bytes = (h) => util.hexToBytes(h.startsWith("0x") ? h : "0x" + h);

function contract(name) {
  for (const cs of Object.values(build)) if (cs[name]) return cs[name];
  throw new Error("no contract " + name);
}

async function makeVM() {
  const common = new Common({ chain: Mainnet, hardfork: Hardfork.Cancun });
  const vm = await createVM({ common });
  let ts = 1_000_000n;
  const block = () => ({
    header: {
      number: 1n,
      timestamp: ts,
      gasLimit: 30_000_000n,
      baseFeePerGas: 0n,
      coinbase: util.createZeroAddress(),
      difficulty: 0n,
      prevRandao: new Uint8Array(32),
      getBlobGasPrice: () => 0n,
    },
  });
  const accounts = {};
  async function fund(who, wei = 10n ** 20n) {
    const a = util.createAddressFromString(who);
    await vm.stateManager.putAccount(a, util.createAccount({ balance: wei, nonce: 0n }));
  }
  async function deploy(name, args = [], types = []) {
    const c = contract(name);
    const iface = new Interface(c.abi);
    const data = c.evm.bytecode.object + (types.length ? coder.encode(types, args).slice(2) : "");
    const r = await vm.evm.runCall({
      caller: util.createAddressFromString(DEPLOYER),
      data: bytes(data),
      gasLimit: 10_000_000n,
      block: block(),
    });
    if (r.execResult.exceptionError) throw new Error("deploy failed: " + r.execResult.exceptionError.error);
    return { address: r.createdAddress.toString(), iface, name };
  }
  async function call(c, fn, args = [], { from = DEPLOYER, value = 0n } = {}) {
    const data = c.iface.encodeFunctionData(fn, args);
    const r = await vm.evm.runCall({
      caller: util.createAddressFromString(from),
      to: util.createAddressFromString(c.address),
      data: bytes(data),
      value,
      gasLimit: 10_000_000n,
      block: block(),
    });
    const logs = (r.execResult.logs || []).map(([addr, topics, d]) => {
      try {
        return c.iface.parseLog({ topics: topics.map(hex), data: hex(d) });
      } catch {
        return null;
      }
    }).filter(Boolean);
    if (r.execResult.exceptionError) {
      let reason = r.execResult.exceptionError.error;
      const rv = hex(r.execResult.returnValue);
      if (rv.startsWith("0x08c379a0")) reason = coder.decode(["string"], "0x" + rv.slice(10))[0];
      const e = new Error(reason);
      e.reverted = true;
      throw e;
    }
    const out = c.iface.decodeFunctionResult(fn, hex(r.execResult.returnValue));
    return { out, logs, gas: r.execResult.executionGasUsed };
  }
  async function balance(who) {
    const a = await vm.stateManager.getAccount(util.createAddressFromString(who));
    return a ? a.balance : 0n;
  }
  return { vm, fund, deploy, call, balance, warp: (t) => (ts = BigInt(t)), now: () => ts };
}

const DEPLOYER = "0x1000000000000000000000000000000000000001";
module.exports = { makeVM, DEPLOYER, keccak256, coder, hexlify, randomBytes };
