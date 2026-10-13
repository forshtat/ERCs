# Odos Router V2 swapCompact test vectors

Calls to `swapCompact()` on Odos Router V2 on Ethereum. All arguments are packed after the selector and read from `@.data`.

Descriptor: [`example-odos-swap-compact.json`](./example-odos-swap-compact.json)

## ETH to USDC, received by the sender

The input token tag is `0x0000`, the zero address standing for ETH. Both receiver tags are `0x0000`: the input goes to the executor and the output to the sender.

- Chain ID: 1
- From: `0x1111111111111111111111111111111111111111`
- To: `0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559`
- Value: 1 ETH

Calldata:

```
0x83bd37f900000001a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48080de0b6b3a7640000049502f9000147ae0001e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e000000000000000000201010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202
```

Expected display:

```
Intent: Swap
Amount in: 1 ETH
Quoted amount out: 2500 USDC
Slippage tolerance (in units of 1/16777215 of the quote): 83886
Executor: 0xe0E0e0e0e0E0E0e0E0e0e0e0e0e0E0e0e0e0e0e0
Input sent to: 0xe0E0e0e0e0E0E0e0E0e0e0e0e0e0E0e0e0e0e0e0
Recipient: 0x1111111111111111111111111111111111111111
Referral code: 0
```

## USDC to WETH, input sent straight to a pool, output to another address

- Chain ID: 1
- From: `0x1111111111111111111111111111111111111111`
- To: `0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559`
- Value: 0 ETH

Calldata:

```
0x83bd37f90001a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480001c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2043b9aca0008058d15e176280000028f5c0001e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0000188e6a0c2ddd26feeb64f039a2c41296fcb3f56400001b0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb000000010201010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202
```

Expected display:

```
Intent: Swap
Amount in: 1000 USDC
Quoted amount out: 0.4 WETH
Slippage tolerance (in units of 1/16777215 of the quote): 167772
Executor: 0xe0E0e0e0e0E0E0e0E0e0e0e0e0e0E0e0e0e0e0e0
Input sent to: 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
Recipient: 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb
Referral code: 1
```

## Output token taken from the router's cached address list

Tag `0x0007` refers to an address stored in the router, which is not part of the transaction's input. The descriptor rejects it.

- Chain ID: 1
- From: `0x1111111111111111111111111111111111111111`
- To: `0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559`
- Value: 0 ETH

Calldata:

```
0x83bd37f90001a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480007043b9aca0008058d15e176280000028f5c0001e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e000000000000000000201010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202
```

Expected display:

```
Rejected: no case for value 0x07
```
