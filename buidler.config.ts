import { BuidlerConfig, usePlugin } from "@nomiclabs/buidler/config";
import { privateKey } from "./wallet";

usePlugin("@nomiclabs/buidler-ethers");
usePlugin("solidity-coverage");
usePlugin('buidler-contract-sizer');


if (process.env.REPORT_GAS) {
    usePlugin("buidler-gas-reporter");
}


const config: BuidlerConfig = {
    solc: {
        version: "0.7.0",
        optimizer: { enabled: true, runs: 2000 }
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

export default config;
