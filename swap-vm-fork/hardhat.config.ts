import { defineConfig, configVariable } from "hardhat/config";
import hardhatEthers from "@nomicfoundation/hardhat-ethers";
import hardhatIgnition from "@nomicfoundation/hardhat-ignition";
import hardhatKeystore from "@nomicfoundation/hardhat-keystore";
import hardhatVerify from "@nomicfoundation/hardhat-verify";
import hardhatNodeTestRunner from "@nomicfoundation/hardhat-node-test-runner";
import hardhatContractSizer from "@solidstate/hardhat-contract-sizer";
import hardhatIgnoreWarnings from "hardhat-ignore-warnings";

const swapVmCompiler = {
  version: "0.8.30",
  settings: {
    evmVersion: "prague",
    optimizer: { enabled: true, runs: 600 },
    viaIR: true,
  },
  preferWasm: false,
};

const fastTestCompiler = {
  version: "0.8.30",
  settings: {
    evmVersion: "prague",
    viaIR: true,
    optimizer: {
      enabled: true,
      runs: 1,
      details: {
        yul: true,
        cse: false,
        constantOptimizer: false,
        inliner: false,
        peephole: false,
        jumpdestRemover: false,
        orderLiterals: false,
        deduplicate: false,
      },
    },
  },
  preferWasm: false,
};

export default defineConfig({
  plugins: [
    hardhatIgnoreWarnings,
    hardhatEthers,
    hardhatIgnition,
    hardhatKeystore,
    hardhatVerify,
    hardhatNodeTestRunner,
    hardhatContractSizer,
  ],
  solidity: {
    npmFilesToBuild: ["@1inch/solidity-utils/contracts/mocks/TokenMock.sol"],
    splitTestsCompilation: true,
    profiles: {
      default: { isolated: true, compilers: [swapVmCompiler] },
      production: { isolated: true, compilers: [swapVmCompiler] },
      fast: { isolated: true, compilers: [fastTestCompiler] },
    },
  },
  coverage: {
    skipFiles: [
      "contracts/opcodes/Opcodes.sol",
      "contracts/opcodes/*Debug.sol",
      "contracts/routers/SwapVMRouter.sol",
      "contracts/routers/*Debug.sol",
    ],
  },
  test: {
    solidity: {
      fuzz: {
        runs: 1024,
      },
      fsPermissions: {
        readDirectory: ["./node_modules/@1inch/solidity-utils/dist/src"],
        dangerouslyReadWriteDirectory: ["./deployments", "./config"],
      },
    },
  },
  networks: {
    localhost: {
      type: "http",
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    // Base Sepolia — added for the Gap WeekendGap-opcode redeploy (Task 10, Step 5).
    // Gated on BASE_SEPOLIA_RPC_URL / BASE_SEPOLIA_PRIVATE_KEY config variables; Hardhat 3
    // resolves these from env vars of the same name (or the encrypted keystore). The live
    // deploy is deferred to the user's gated run — see script/redeploy-base-sepolia.sh.
    baseSepolia: {
      type: "http",
      url: configVariable("BASE_SEPOLIA_RPC_URL"),
      chainId: 84532,
      accounts: [configVariable("BASE_SEPOLIA_PRIVATE_KEY")],
    },
  },
  verify: {
    etherscan: {
      apiKey: configVariable("ETHERSCAN_API_KEY"),
    },
  },
  contractSizer: {
    only: [/contracts\/routers\//],
    except: [/Debug/],
  },
  warnings: {
    "test/solidity/**/*": {
      "initcode-size": "off",
      "func-mutability": "off",
      "unused-param": "off",
      "unused-var": "off",
      "unused-call-retval": "off",
    },
    "test/solidity/helpers/SwapVMTestSetup.sol": {
      "shadowing": "off",
    },
    "contracts/routers/*Debug.sol": {
      "code-size": "off",
    },
    "contracts/routers/SwapVMRouter.sol": {
      "code-size": "off",
    },
    "npm/@1inch/solidity-utils@*/**/*": {
      "transient-storage": "off",
    },
  },
});
