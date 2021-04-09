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
        version: "0.7.6",
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
        bsctestnet: {
            url: 'https://data-seed-prebsc-1-s1.binance.org:8545/',
            chainId: 97,
            gasPrice: 20000000000,
            accounts: [privateKey],
        },
        bscmainnet: {
            url: "https://bsc-dataseed.binance.org/",
            chainId: 56,
            gasPrice: 20000000000,
            accounts: [privateKey]
        },
        coverage: {
            url: 'http://localhost:8555'
        }
    }
};

export default config;