import { l2ethers, ethers } from "hardhat";
import { Signer } from "ethers";
import contracts from "./contracts.json"
import { LiquifiActivityMeter } from "../typechain/LiquifiActivityMeter";

let signer: Signer;

async function main() {
  signer = (await ethers.getSigners())[0];
  const activityMeter = await ethers.getContractAt("LiquifiActivityMeter", contracts.activityMeter) as LiquifiActivityMeter;

  console.log("Activity Meter update counter:", (await activityMeter.counter()).toString())
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
