// Hardhat script
const SortedTroves = artifacts.require("./SortedTroves.sol")
const TroveManager = artifacts.require("./TroveManager.sol")
const PriceFeed = artifacts.require("./PriceFeed.sol")
const LUSDToken = artifacts.require("./LUSDToken.sol")
const ActivePool = artifacts.require("./ActivePool.sol");
const DefaultPool = artifacts.require("./DefaultPool.sol");
const StabilityPool = artifacts.require("./StabilityPool.sol")
const FunctionCaller = artifacts.require("./FunctionCaller.sol")
const BorrowerOperations = artifacts.require("./BorrowerOperations.sol")

const LQTYStaking = artifacts.require("./LQTY/LQTYStaking.sol")
const LQTYToken = artifacts.require("./LQTY/LQTYToken.sol")
const LockupContractFactory = artifacts.require("./LQTY/LockupContractFactory.sol")
const CommunityIssuance = artifacts.require("./LQTY/CommunityIssuance.sol")
const HintHelpers = artifacts.require("./HintHelpers.sol")

const CommunityIssuanceTester = artifacts.require("./LQTY/CommunityIssuanceTester.sol")
const ActivePoolTester = artifacts.require("./ActivePoolTester.sol")
const DefaultPoolTester = artifacts.require("./DefaultPoolTester.sol")
const MathTester = artifacts.require("./LiquityMathTester.sol")
const BorrowerOperationsTester = artifacts.require("./BorrowerOperationsTester.sol")
const TroveManagerTester = artifacts.require("./TroveManagerTester.sol")
const LUSDTokenTester = artifacts.require("./LUSDTokenTester.sol")

const dh = require("./deploymentHelpers.js")

const coreContractABIs = [
  BorrowerOperations,
  PriceFeed,
  LUSDToken,
  SortedTroves,
  TroveManager,
  ActivePool,
  StabilityPool,
  DefaultPool,
  FunctionCaller,
  HintHelpers,
]

const LQTYContractABIs = [
  LQTYStaking,
  LQTYToken,
  LockupContractFactory,
  CommunityIssuance
]

const TesterContractABIs  = [
  CommunityIssuanceTester,
  ActivePoolTester,
  DefaultPoolTester,
  MathTester,
  BorrowerOperationsTester,
  TroveManagerTester,
  LUSDTokenTester,
]

const getGasFromContractDeployment = async (contractObject, name) => {
  const txHash = contractObject.transactionHash
  // console.log(`tx hash  of ${name} deployment is is: ${txHash}`)
  const receipt = await ethers.provider.getTransactionReceipt(txHash)
  const gas = receipt.gasUsed
  console.log(`${name}: ${gas}`)
  return gas
}

const getBytecodeSize = (contractABI) => {
  const bytecodeLength = (contractABI.bytecode.length / 2) - 1
  const deployedBytecodeLength = (contractABI.deployedBytecode.length / 2) - 1
  console.log(`${contractABI.contractName}: ${bytecodeLength}`)
  // console.log(`${contractABI.contractName} deployed bytecode length: ${deployedBytecodeLength}`)
}

const getUSDCostFromGasCost = (deploymentGasTotal, gasPriceInGwei, ETHPrice) => {
  const dollarCost = (deploymentGasTotal * gasPriceInGwei * ETHPrice) / 1e9
  console.log(`At gas price ${gasPriceInGwei} GWei, and ETH Price $${ETHPrice} per ETH, the total cost of deployment in USD is: $${dollarCost}`)
}

const logContractDeploymentCosts = async (contracts) => {
  console.log(`Gas costs for deployments: `)
  let totalGasCost = 0
  for (contractName of Object.keys(contracts)) {
    const gasCost = await getGasFromContractDeployment(contracts[contractName], contractName);
    totalGasCost = totalGasCost + Number(gasCost)
  }
  console.log(`Total deployment gas costs: ${totalGasCost}`)
  getUSDCostFromGasCost(totalGasCost, 200, 500)
}

const logContractBytecodeLengths = (contractABIs) => {
  console.log(`Contract bytecode lengths:`)
  for (abi of contractABIs) {
    getBytecodeSize(abi)
  }
}

// Run script: log deployment gas costs and bytecode lengths for all contracts
async function main() {
  const coreContracts = await dh.deployLiquityCoreHardhat()
  const LQTYContracts = await dh.deployLQTYContractsHardhat()
  const testerContracts = await dh.deployTesterContractsHardhat()

  await dh.connectCoreContracts(coreContracts, LQTYContracts)
  await dh.connectLQTYContracts(LQTYContracts)
  await dh.connectLQTYContractsToCore(LQTYContracts, coreContracts)


  console.log(`\n`)
  console.log(`LQTY CONTRACTS`)
  await logContractDeploymentCosts(LQTYContracts)
  console.log(`\n`)
  logContractBytecodeLengths(LQTYContractABIs)
  console.log(`\n`)

  console.log(`CORE CONTRACTS`)
  await logContractDeploymentCosts(coreContracts)
  console.log(`\n`)
  logContractBytecodeLengths(coreContractABIs)
  console.log(`\n`)

  console.log(`TESTER CONTRACTS`)
  await logContractDeploymentCosts(testerContracts)
  console.log(`\n`)
  logContractBytecodeLengths(TesterContractABIs)
  console.log(`\n`)


  
  const OYLCdeployment = await LQTYContracts.lockupContractFactory.deployOneYearLockupContract('0x0000000000000000000000000000000000000000', 100)
  const OYLCdeploymentGasCost = OYLCdeployment.receipt.gasUsed
  console.log(`OYLC deployment through factory gas cost:${OYLCdeploymentGasCost }`)


}

main()
  .then(() => process.exit(0))
  .catch(error => {
    console.error(error);
    process.exit(1);
  });
