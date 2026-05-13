require('@nomicfoundation/hardhat-ethers')
require('dotenv').config()

module.exports = {
  solidity: {
    version: '0.8.24',
    settings: { optimizer: { enabled: true, runs: 200 }, evmVersion: 'cancun' },
  },
  networks: {
    kite_testnet: {
      url: 'https://rpc-testnet.gokite.ai/',
      chainId: 2368,
      accounts: process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [],
    },
    kite: {
      url: 'https://rpc.gokite.ai/',
      chainId: 2366,
      accounts: process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [],
    },
  },
}
