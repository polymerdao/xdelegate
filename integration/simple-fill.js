import 'dotenv/config'
import { createWalletClient, createPublicClient, http, encodeAbiParameters, keccak256, encodeEventTopics } from 'viem'
import { baseSepolia, optimismSepolia } from 'viem/chains'
import { privateKeyToAccount } from 'viem/accounts'
import SimpleOriginSettler from '../out/SimpleOriginSettler.sol/SimpleOriginSettler.json' assert { type: 'json' }
import SimpleDestinationSettler from '../out/SimpleDestinationSettler.sol/SimpleDestinationSettler.json' assert { type: 'json' }
import HelloWorld from '../out/HelloWorld.sol/HelloWorld.json' assert { type: 'json' }
import { CallByUserDefinition } from './structs.js'
import fetch from 'node-fetch'

const userKey = process.env.PRIVATE_KEY
const user = privateKeyToAccount(userKey)

// Create clients for both chains
const baseClient = createWalletClient({
    chain: baseSepolia,
    transport: process.env.BASE_SEPOLIA_RPC_URL? http(process.env.BASE_SEPOLIA_RPC_URL) : http(),
    account: user,
})

const optimismClient = createWalletClient({
    chain: optimismSepolia,
    transport: process.env.OP_SEPOLIA_RPC_URL? http(process.env.OP_SEPOLIA_RPC_URL) : http(),
    account: user,
})

const basePublicClient = createPublicClient({
    chain: baseSepolia,
    transport: process.env.BASE_SEPOLIA_RPC_URL? http(process.env.BASE_SEPOLIA_RPC_URL) : http(),
})

const optimismPublicClient = createPublicClient({
    chain: optimismSepolia,
    transport:process.env.OP_SEPOLIA_RPC_URL? http(process.env.OP_SEPOLIA_RPC_URL) : http(),
})

const POLYMER_API_URL = 'https://proof.sepolia.polymer.zone'
const POLYMER_API_KEY = process.env.POLYMER_API_KEY

async function requestReceiptProof(srcChainId, dstChainId, blockNumber, txIndex) {
    const response = await fetch(POLYMER_API_URL, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${POLYMER_API_KEY}`,
        },
        body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'receipt_requestProof',
            params: [srcChainId, dstChainId, blockNumber, txIndex],
        },(key, value) => {
            if (typeof value === 'bigint' || typeof value ==="BigInt") {
              return Number( value);
            }
            return value;
          }) 
    })
    const data = await response.json()
    return data.result // jobID
}

async function queryReceiptProof(jobId) {
    const response = await fetch(POLYMER_API_URL, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${POLYMER_API_KEY}`,
        },
        body: JSON.stringify({
            jsonrpc: '2.0',
            id: 1,
            method: 'receipt_queryProof',
            params: [jobId],
        }),
    })
    const data = await response.json()
    return data.result
}

async function pollForProof(jobId, maxAttempts = 30, interval = 2000) {
    for (let i = 0; i < maxAttempts; i++) {
        const result = await queryReceiptProof(jobId)

        if (result.status === 'complete') {
            return result.proof
        }

        if (result.status === 'error') {
            throw new Error(`Proof generation failed for jobId ${jobId}`)
        }

        // If pending, wait and try again
        await new Promise((resolve) => setTimeout(resolve, interval))
    }
    throw new Error('Proof polling timed out')
}

async function main() {
    console.log('Starting cross-chain transaction...')

    // Create the call to HelloWorld.hello()
    const calls = [
        {
            target: process.env.HELLOWORLD_ADDRESS,
            callData: '0x19ff1d21', // hello()
            value: 0n,
        },
    ]

    // Create CallByUser data
    const callsByUser = {
        user: user.address,
        nonce: 20n,
        asset: {
            token: '0x0000000000000000000000000000000000000000',
            amount: 0n,
        },
        chainId: BigInt(optimismSepolia.id),
        signature: '0x',
        calls: calls,
    }

    // Encode the CallByUser data for the destination chain
    const originData = encodeAbiParameters([CallByUserDefinition], [callsByUser])

    // Calculate the orderId
    const orderId = keccak256(originData)

    console.log('Opening order on Base Sepolia...')

    // Open the order on Base Sepolia
    const openTxHash = await baseClient.writeContract({
        address: process.env.ORIGINSETTLER_ADDRESS,
        abi: SimpleOriginSettler.abi,
        functionName: 'open',
        args: [optimismSepolia.id, callsByUser, process.env.DESTINATIONSETTLER_ADDRESS],
        value: BigInt(1e14), // 0.0001 ETH as reward
    })

    console.log('Waiting for open transaction:', openTxHash)
    await basePublicClient.waitForTransactionReceipt({ hash: openTxHash })

    console.log('Order opened. Filling on Optimism Sepolia...')

    // Fill the order on Optimism Sepolia
    const fillTxHash = await optimismClient.writeContract({
        address: process.env.DESTINATIONSETTLER_ADDRESS,
        abi: SimpleDestinationSettler.abi,
        functionName: 'fill',
        args: [orderId, originData],
    })

    console.log('Waiting for fill transaction:', fillTxHash)
    const fillReceipt = await optimismPublicClient.waitForTransactionReceipt({ hash: fillTxHash })

    // Get block details for the fill transaction
    const block = await optimismPublicClient.getBlock({
        blockHash: fillReceipt.blockHash,
    })

    // Get transaction index
    const txIndex = fillReceipt.transactionIndex

    // Find the OrderExecuted event log index

    const orderExecutedTopic = encodeEventTopics({ abi: SimpleDestinationSettler.abi, eventName: "OrderExecuted",  args:{
        orderId
    }})

    const logIndex = fillReceipt.logs.findIndex((log) => {
        return log.address.toLowerCase() === process.env.DESTINATIONSETTLER_ADDRESS.toLowerCase() && log.topics[0] === orderExecutedTopic[0]
    })
    console.log('log index:', logIndex)

    if (logIndex === -1) {
        throw new Error('OrderExecuted event not found in logs')
    }

    console.log('Fill transaction details:')
    console.log('- Block number:', block.number)
    console.log('- Transaction index:', txIndex)
    console.log('- Log index:', logIndex)

    // Request proof from Optimism Sepolia to Base Sepolia
    console.log('Requesting receipt proof...')
    const jobId = await requestReceiptProof(
        optimismSepolia.id, // source chain
        baseSepolia.id, // destination chain
        block.number,
        txIndex
    )
    console.log('Proof job ID:', jobId)

    // Poll for proof completion
    console.log('Polling for proof completion...')
    const proof = await pollForProof(jobId)
    console.log('Proof received:', proof)
    const encodedProof = encodeToHex(proof)
    console.log('Proof encoded:', encodedProof)

    // TODO: Submit proof to SimpleOriginSettler.repayFiller()
    console.log('Submitting proof to claim reward')
    const repayTxHash = await baseClient.writeContract({
        address: process.env.ORIGINSETTLER_ADDRESS,
        abi: SimpleOriginSettler.abi,
        functionName: 'repayFiller',
        args: [orderId, process.env.ADDRESS, logIndex, encodedProof],
    })

    console.log('Waiting for repay transaction:', repayTxHash)
    await basePublicClient.waitForTransactionReceipt({ hash: repayTxHash })
}


const encodeToHex = ( s ) =>{
    const binaryString = atob(s);
    let hexString = '';
    for (let i = 0; i < binaryString.length; i++) {
      const charCode = binaryString.charCodeAt(i);
      const hex = charCode.toString(16).padStart(2, '0'); 
      hexString += hex;
    }
    return `0x${hexString.toUpperCase()}`;
}


main().catch(console.error)
