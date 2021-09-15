const fs = require('fs/promises');
const path = require('path');

async function initContractData(contractName, data = {}) {
  const { deployment } = hre.deployer;
  const { sourceName, abi, bytecode, deployedBytecode } = await hre.artifacts.readArtifact(
    contractName
  );

  const sourceCode = (
    await fs.readFile(path.resolve(hre.config.paths.root, sourceName))
  ).toString();

  deployment.data.contracts[contractName] = {
    deployedAddress: '',
    deployTransaction: '',
    bytecodeHash: '',
    ...data,
    sourceName,
  };

  deployment.abis[contractName] = abi;

  deployment.sources[contractName] = {
    bytecode,
    deployedBytecode,
    sourceCode,
  };
}

module.exports = {
  initContractData,
};
