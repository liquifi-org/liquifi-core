import { BigNumber, utils, ContractTransaction } from "ethers";
import { LiquifiDelayedExchangePool } from "../../typechain/LiquifiDelayedExchangePool";

export function traceDebugEvents(contract: any, eventsCount: number = 1, asHex = false) {
    return new Promise((resolve, reject) => {
        contract.on("DebugEvent", (text: any, value: any, event: any) => {
            console.log(text + ": " + (asHex ? BigNumber.from(value).toHexString() : BigNumber.from(value).toString()));

            if (--eventsCount == 0) {
                event.removeListener();
                resolve();
            }
        });
        
        setTimeout(() => {
            reject(new Error('timeout while waiting for event'));
        }, 30000);
    });
}

// TODO: replace this with orderHistory
export function collectEvents(contract: any, eventsCount: number = 1, eventName: string = "FlowBreakEvent"): Promise<any[]> {
    const events : any[] = [];
    return new Promise((resolve, reject) => {
        contract.on(eventName, (...args: any[]) => {
            const event = args[args.length - 1] as any;

            if (events.length < eventsCount) {
                events.push(args.slice(0, -1));
            }

            if (events.length == eventsCount) {
                event.removeListener();
                resolve(events);
            }
        });
        
        setTimeout(() => {
            reject(new Error('timeout while waiting for event'));
        }, 30000);
    });
}

export async function poolFlowBreaks(pool: LiquifiDelayedExchangePool, fromBlock: number | undefined): Promise<utils.LogDescription[]> {
    const eventFragment = pool.interface.getEvent("FlowBreakEvent");
    const topic = pool.interface.getEventTopic(eventFragment);
    const filter = { topics: [topic], address: pool.address, fromBlock: fromBlock  };
    const logs = await pool.provider.getLogs(filter);
    return logs.map(log => pool.interface.parseLog(log));
}

export async function orderHistory(pool: LiquifiDelayedExchangePool, addOrderTx: ContractTransaction, orderId: BigNumber): Promise<[string, BigNumber[]]> {
    const flowBreaks = await poolFlowBreaks(pool, addOrderTx.blockNumber);
    const openIndex = flowBreaks.findIndex(item => item.args.orderId.eq(orderId));
    const closeIndex = flowBreaks.findIndex(item => item.args.orderId.eq(orderId) && item.args.others.and(1).eq(1));
    const orderBreaks = [];
    for(const item of flowBreaks.slice(openIndex, closeIndex > 0 ? closeIndex + 1 : undefined)) {
        orderBreaks.push(item.args.availableBalance, item.args.flowSpeed, item.args.others);
    }
    return [flowBreaks[openIndex].args.lastBreakHash, orderBreaks];
}

export const lastBlockTimestamp = async (ethers: any): Promise<BigNumber> => {
    const lastBlockNumber = await ethers.provider.send("eth_blockNumber", []); 
    const lastBlock = await ethers.provider.send("eth_getBlockByNumber", [lastBlockNumber, true]);
    return BigNumber.from(lastBlock.timestamp);
} 

export const wait = async (ethers: any , seconds: number) => {
    await ethers.provider.send("evm_increaseTime", [seconds - 1]);   
    await ethers.provider.send("evm_mine", []); // mine the next block
}