import contracts from "./contracts.json"

export const wethAddress: {[key: string]: string} = {
    ropsten: '0xc778417E063141139Fce010982780140Aa0cD5Ab',
    kovan: '0xf3a6679b266899042276804930b3bfbaf807f15b',
    rinkeby: '0xc778417E063141139Fce010982780140Aa0cD5Ab',
    mainnet: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    local: contracts.weth
};