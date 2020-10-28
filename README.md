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
#### Current Contracts (Ropsten, old contracts):
- LiquiFi Pool Factory address: `0xdE39De4B146B30E67C4E73c176E47fEfFF7e563A`
- LiquiFi Pool Register address: `0x5da7C78846367ff186a7B1e6B8A2b9d09744c055`

#### Current Contracts (Rinkeby):
- LiquiFi Pool Factory address: `0x6E00b164A06397Fb0c1F43bA61D8E3Ff1f944e5c`
- LiquiFi Pool Register address: `0x4F433BD31c1c5393B6F86E0d287D59e62FdF4cfd`

Create file `wallet.ts` with the following content:
```ts
export const privateKey = 'YOUR-PRIVATE-KEY'
```

Run deploy script:

```sh
npm run deploy
```


