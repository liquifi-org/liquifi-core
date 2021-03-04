import { l2ethers, ethers, network } from "hardhat";
import { Signer } from "ethers";
import {
  LiquifiActivityMeterFactory,
  LiquifiMinterFactory,
} from "../typechain";
import { storeAddresses } from "./addresses";

let signer: Signer;

async function deployMinter() {
  const LiquifiMinter = (await l2ethers.getContractFactory(
    "LiquifiMinter"
  )) as LiquifiMinterFactory;
  const liquifiMinter = await LiquifiMinter.connect(signer).deploy();
  await liquifiMinter.deployed();
  console.log("LiquiFi Minter address:", liquifiMinter.address);
  console.log(await ethers.provider.getCode(liquifiMinter.address));
  return liquifiMinter;
}

async function deployActivityMeter(minterAddress: any) {
  const LiquifiActivityMeter = (await l2ethers.getContractFactory(
    "LiquifiActivityMeter"
  )) as LiquifiActivityMeterFactory;
  const liquifiActivityMeter = await LiquifiActivityMeter.connect(
    signer
  ).deploy(minterAddress, 7 * 24 * 60 * 60);
  await liquifiActivityMeter.deployed();
  console.log("LiquiFi Activity Meter address:", liquifiActivityMeter.address);
  console.log(await ethers.provider.getCode(liquifiActivityMeter.address));
  return liquifiActivityMeter;
}

async function main() {
  signer = (await ethers.getSigners())[0];
  const minter = await deployMinter();
  const activityMeter = await deployActivityMeter(minter.address);
  await minter.setActivityMeter(activityMeter.address);

  storeAddresses({
      minter: minter.address,
      activityMeter: activityMeter.address
  })
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
