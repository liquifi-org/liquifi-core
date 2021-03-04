import chai, { expect } from 'chai'
import { solidity } from 'ethereum-waffle'

chai.use(solidity)

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

export { expect, ZERO_ADDRESS }