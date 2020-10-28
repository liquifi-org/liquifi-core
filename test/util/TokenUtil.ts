import { BigNumber } from "ethers"
export const token = (value: Number) => BigNumber.from(value).mul(BigNumber.from(10).pow(18))
