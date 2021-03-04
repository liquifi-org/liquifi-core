import { utils } from "ethers"
import { ethers } from "hardhat"
import { Erc20Token } from "../typechain/Erc20Token"
import contracts from "./contracts.json"
import { loadContracts, loadPool, loadToken } from "./liquifi"

const l2Messenger = "0x6418E5Da52A3d7543d393ADD3Fa98B0795d27736"
const timeout = 42949672960

async function main() {
    const signer = (await ethers.getSigners())[0]
    const liquifi = await loadContracts(ethers)
    const crp = await loadToken(ethers, contracts.crp)
    const fsh = await loadToken(ethers, contracts.fsh)

    console.log("crp balance:", await balanceOf(crp, await signer.getAddress()))
    console.log("fsh balance:", await balanceOf(fsh, await signer.getAddress()))

    await crp.connect(signer).approve(contracts.register, tokens(1000))
    await fsh.connect(signer).approve(contracts.register, tokens(1000))
    // await liquifi.poolRegister.connect(signer)
    //     .deposit(
    //         contracts.crp, 
    //         ethers.utils.parseEther("1000"), 
    //         contracts.fsh, 
    //         ethers.utils.parseEther("1000"), 
    //         await signer.getAddress(), 
    //         timeout
    //     )
    await liquifi.poolRegister.connect(signer)
        .depositWithETH(
            contracts.crp,
            ethers.utils.parseEther("1000"),
            await signer.getAddress(),
            timeout,
            {value: tokens(1)}
        )

    // const pool = await loadPool(ethers, crp.address, fsh.address)
    // console.log(await pool.activityReporter())
}

const tokens = (amount: number) => ethers.utils.parseEther(String(amount))
const balanceOf = async (token: Erc20Token, owner: string) => ethers.utils.formatEther((await token.balanceOf(owner)).toString())

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });