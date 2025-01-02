import 'dotenv/config'
import { privateKeyToAccount } from 'viem/accounts'
import { createWalletClient, createPublicClient, http } from 'viem'
import { optimismSepolia, baseSepolia } from 'viem/chains'
import SimpleDestinationSettler from '../out/SimpleDestinationSettler.sol/SimpleDestinationSettler.json' assert { type: 'json' }
import SimpleOriginSettler from '../out/SimpleOriginSettler.sol/SimpleOriginSettler.json' assert { type: 'json' }
import HelloWorld from '../out/HelloWorld.sol/HelloWorld.json' assert { type: 'json' }

const deployerKey = process.env.PRIVATE_KEY
const deployer = privateKeyToAccount(deployerKey)

// Deploy to Optimism Sepolia
async function deployToOptimism() {
    console.log('\nDeploying to Optimism Sepolia...')
    
    const optimismClient = createWalletClient({
        chain: optimismSepolia,
        transport: http(),
        account: deployer,
    })
    
    const publicClient = createPublicClient({
        chain: optimismSepolia,
        transport: http(),
    })

    const nonce = await publicClient.getTransactionCount({ address: deployer.address })
    console.log('current optimism nonce:', nonce)

    // Deploy SimpleDestinationSettler and HelloWorld
    const hashes = await Promise.all([
        SimpleDestinationSettler,
        HelloWorld
    ].map((contract, idx) =>
        optimismClient.deployContract({
            abi: contract.abi,
            bytecode: contract.bytecode.object,
            nonce: nonce + idx,
        })
    ))

    console.log('waiting for optimism receipts ->', hashes)

    const receipts = await Promise.all(hashes.map(hash => 
        publicClient.waitForTransactionReceipt({
            hash,
            pollingInterval: 1000,
        })
    ))

    console.log('SimpleDestinationSettler address (Optimism) ->', receipts[0].contractAddress)
    console.log('HelloWorld address (Optimism) ->', receipts[1].contractAddress)
    
    return receipts
}

// Deploy to Base Sepolia
async function deployToBase() {
    console.log('\nDeploying to Base Sepolia...')
    
    const baseClient = createWalletClient({
        chain: baseSepolia,
        transport: http(),
        account: deployer,
    })
    
    const publicClient = createPublicClient({
        chain: baseSepolia,
        transport: http(),
    })

    const nonce = await publicClient.getTransactionCount({ address: deployer.address })
    console.log('current base nonce:', nonce)

    // Deploy SimpleOriginSettler
    const hash = await baseClient.deployContract({
        abi: SimpleOriginSettler.abi,
        bytecode: SimpleOriginSettler.bytecode.object,
        nonce,
    })

    console.log('waiting for base receipt ->', hash)

    const receipt = await publicClient.waitForTransactionReceipt({
        hash,
        pollingInterval: 1000,
    })

    console.log('SimpleOriginSettler address (Base) ->', receipt.contractAddress)
    
    return receipt
}

// Main deployment function
async function deploy() {
    try {
        console.log('Starting deployments...')
        console.log('Deployer address:', deployer.address)

        // Deploy to both chains
        const [optimismReceipts, baseReceipt] = await Promise.all([
            deployToOptimism(),
            deployToBase()
        ])

        // Log all deployed addresses together
        console.log('\nDeployed Contract Addresses:')
        console.log('--------------------------------')
        console.log('Optimism Sepolia:')
        console.log('- SimpleDestinationSettler:', optimismReceipts[0].contractAddress)
        console.log('- HelloWorld:', optimismReceipts[1].contractAddress)
        console.log('Base Sepolia:')
        console.log('- SimpleOriginSettler:', baseReceipt.contractAddress)

    } catch (error) {
        console.error('Deployment failed:', error)
    }
}

// Execute deployment
deploy() 