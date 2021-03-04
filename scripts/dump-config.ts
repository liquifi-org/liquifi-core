import contracts from "./contracts.json"

function main() {
    console.log(`
    - "POOL_FACTORY_ADDRESS=${contracts.factory}"
    - "POOL_REGISTER_ADDRESS=${contracts.register}"
    - "GOVERNANCE_ROUTER_ADDRESS=${contracts.governanceRouter}"
    - "ACTIVITY_METER_ADDRESS=${contracts.activityMeter}"
    - "MINTER_ADDRESS=${contracts.minter}"
    `)

    console.log(`
      {
        "name": "CRP",
        "address": "${contracts.crp}",
        "symbol": "CRP",
        "decimals": 18,
        "chainId": 31337,
        "logoURI": "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xB6eD7644C69416d67B522e20bC294A9a9B405B31/logo.png"
      },
      {
        "name": "Wrapped ETH",
        "address": "${contracts.weth}",
        "symbol": "WETH",
        "decimals": 18,
        "chainId": 31337,
        "logoURI": "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xB6eD7644C69416d67B522e20bC294A9a9B405B31/logo.png"
      },
      {
        "name": "FSH",
        "address": "${contracts.fsh}",
        "symbol": "FSH",
        "decimals": 18,
        "chainId": 31337,
        "logoURI": "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xB6eD7644C69416d67B522e20bC294A9a9B405B31/logo.png"
      },
  `)

  console.log(`
  new TokensMetadata("CRP", "${contracts.crp}", List.of()),
  new TokensMetadata("FSH", "${contracts.fsh}", List.of()),
  new TokensMetadata("WETH", "${contracts.weth}", List.of()  
  `)
}

main()