const CallsDefinition = {
    type: 'tuple[]',
    components: [
        {
            type: 'address',
            name: 'target',
        },
        {
            type: 'bytes',
            name: 'callData',
        },
        {
            type: 'uint256',
            name: 'value',
        },
    ],
}

const CallByUserDefinition = {
    internalType: 'struct CallByUser',
    name: 'calls',
    type: 'tuple',
    components: [
        { internalType: 'address', name: 'user', type: 'address' },
        { internalType: 'uint256', name: 'nonce', type: 'uint256' },
        {
            internalType: 'struct Asset',
            name: 'asset',
            type: 'tuple',
            components: [
                { internalType: 'address', name: 'token', type: 'address' },
                { internalType: 'uint256', name: 'amount', type: 'uint256' },
            ],
        },
        { internalType: 'uint64', name: 'chainId', type: 'uint64' },
        { internalType: 'bytes', name: 'signature', type: 'bytes' },
        {
            internalType: 'struct Call[]',
            name: 'calls',
            type: 'tuple[]',
            components: [
                { internalType: 'address', name: 'target', type: 'address' },
                { internalType: 'bytes', name: 'callData', type: 'bytes' },
                { internalType: 'uint256', name: 'value', type: 'uint256' },
            ],
        },
    ],
}

export { CallByUserDefinition, CallsDefinition }
