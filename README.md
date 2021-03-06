# LiquiFi Ethereum Smart Contracts


### Clean working folder

*ATTENTION!* Please note this task should be executed before each coverage task
```sh
npm run clean
```


### Install dependencies
```sh
npm install
```

### Compile Smart Contracts and Build ABI
```sh
npm run compile
```

Contract ABIs will be located in `artifacts` folder

### Build TypeChain Smart Contract Definitions
```sh
npm run typechain
```

### Run Tests
```sh
npm run test
```

### Run Tests with Coverage
> NB! Use Node v12
```sh
npm run coverage
```

### Run gas measuring tests
```sh
npm run gas-report
```

### Clean working folder
```sh
npm run clean
```



### Deploy Contracts
Create file `wallet.ts` with the following content:
```ts
export const privateKey = 'YOUR-PRIVATE-KEY'
```

Run deploy script:

```sh
npm run deploy
```

```sh
npm run deploy_{networkID}
```

## Networks

|ID|Name|
|----|-------------|
| 1  | Mainnet     |
| 3  | Ropsten     |
| 4  | Rinkeby     |
| 56 | BSC Mainnet |
| 97 | BSC Testnet |
