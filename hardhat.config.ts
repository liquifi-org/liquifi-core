import { privateKey } from "./wallet";
import { HardhatUserConfig } from 'hardhat/types'

import '@eth-optimism/plugins/hardhat/compiler'
import '@eth-optimism/plugins/hardhat/ethers'
import '@nomiclabs/hardhat-ethers'
import '@nomiclabs/hardhat-waffle'

const config: HardhatUserConfig = {
  solidity: {
    version: "0.7.6",
    settings: {
      optimizer: { enabled: true, runs: 2000 }
    }
  },
  networks: {
    ropsten: {
        url: `http://ropsten.node.liquifi.org:8545`,
        accounts: [privateKey],
    },
    rinkeby: {
        url: `http://rinkeby.node.liquifi.org:8545`,
        accounts: [privateKey]
    },
    mainnet: {
        url: 'http://mainnet.node.liquifi.org:8545',
        accounts: [privateKey]
    },
    coverage: {
        url: 'http://localhost:8555'
    }
  }
};

export default config