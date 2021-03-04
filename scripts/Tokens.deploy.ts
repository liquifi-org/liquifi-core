import { ethers } from 'hardhat';
import { Erc20Token } from '../typechain/Erc20Token'
import { TestWeth } from '../typechain/TestWeth';
import { storeAddresses } from './addresses';

const deploy = async () => {
  const signer = (await ethers.getSigners())[0]
  console.log("signer:", await signer.getAddress())
  const ERC20 = await ethers.getContractFactory('ERC20Token');
  
  const crp = (await ERC20.connect(signer).deploy(ethers.utils.parseEther("1000000"), "CRP Token", 18, "CRP")) as Erc20Token
  console.log("CRP address:", crp.address)
  console.log("signer CRP balance:", ethers.utils.formatEther(await crp.balanceOf(await signer.getAddress())))

  const fsh = (await ERC20.connect(signer).deploy(ethers.utils.parseEther("1000000"), "Firmshift Token", 18, "FSH")) as Erc20Token
  console.log("FSH address:", fsh.address)
  console.log("signer FSH balance:", ethers.utils.formatEther(await fsh.balanceOf(await signer.getAddress())))

  const WETH = await ethers.getContractFactory('TestWeth');
  const weth = (await WETH.connect(signer).deploy()) as TestWeth
  console.log("WETH address:", weth.address)
  console.log("signer WETH balance:", ethers.utils.formatEther(await weth.balanceOf(await signer.getAddress())))

  storeAddresses({
    crp: crp.address,
    fsh: fsh.address,
    weth: weth.address,
  })
}

deploy()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error)
    process.exit(1)
  })
