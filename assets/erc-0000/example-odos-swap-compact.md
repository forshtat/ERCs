# Odos Router V2 swapCompact test vectors

Calls to `swapCompact()` on Odos Router V2 on Ethereum. All arguments are packed after the selector and read from `@.data`.

```solidity
// all arguments are packed after the selector
function swapCompact() external payable;
```

Descriptor: [`example-odos-swap-compact.json`](./example-odos-swap-compact.json)

All vectors are sent by `0x1111111111111111111111111111111111111111` to `0xCf5540fFFCdC3d510B18bFcA6d2b9987b0772559` on Ethereum.

## ETH to USDC, received by the sender

Tag `0x0000` means the zero address (ETH) for a token, the executor for the input receiver, and the sender for the output receiver.

Arguments:

```
value: 1 ETH
data after the selector: abi.encodePacked(...)
  inputToken: abi.encodePacked(...)
    tag: 0x0000
  outputToken: abi.encodePacked(...)
    tag: 0x0001
    address: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
  inputAmount: abi.encodePacked(...)
    length: 8
    amount: 1000000000000000000
  outputQuote: abi.encodePacked(...)
    length: 4
    amount: 2500000000
  slippageTolerance: 83886
  executor: abi.encodePacked(...)
    tag: 0x0001
    address: 0xe0E0e0e0e0E0E0e0E0e0e0e0e0e0E0e0e0e0e0e0
  inputReceiver: abi.encodePacked(...)
    tag: 0x0000
  outputReceiver: abi.encodePacked(...)
    tag: 0x0000
  referralCode: 0
  pathLength: 2
  pathDefinition: 0x01010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202
```

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

Arguments:

```
data after the selector: abi.encodePacked(...)
  inputToken: abi.encodePacked(...)
    tag: 0x0001
    address: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
  outputToken: abi.encodePacked(...)
    tag: 0x0001
    address: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
  inputAmount: abi.encodePacked(...)
    length: 4
    amount: 1000000000
  outputQuote: abi.encodePacked(...)
    length: 8
    amount: 400000000000000000
  slippageTolerance: 167772
  executor: abi.encodePacked(...)
    tag: 0x0001
    address: 0xe0E0e0e0e0E0E0e0E0e0e0e0e0e0E0e0e0e0e0e0
  inputReceiver: abi.encodePacked(...)
    tag: 0x0001
    address: 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640
  outputReceiver: abi.encodePacked(...)
    tag: 0x0001
    address: 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb
  referralCode: 1
  pathLength: 2
  pathDefinition: 0x01010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202
```

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

Tag `0x0007` refers to an address stored in the router, which is chain state, so it is rejected.

Arguments:

```
data after the selector: abi.encodePacked(...)
  inputToken: abi.encodePacked(...)
    tag: 0x0001
    address: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
  outputToken: abi.encodePacked(...)
    tag: 0x0007
  inputAmount: abi.encodePacked(...)
    length: 4
    amount: 1000000000
  outputQuote: abi.encodePacked(...)
    length: 8
    amount: 400000000000000000
  slippageTolerance: 167772
  executor: abi.encodePacked(...)
    tag: 0x0001
    address: 0xe0E0e0e0e0E0E0e0E0e0e0e0e0e0E0e0e0e0e0e0
  inputReceiver: abi.encodePacked(...)
    tag: 0x0000
  outputReceiver: abi.encodePacked(...)
    tag: 0x0000
  referralCode: 0
  pathLength: 2
  pathDefinition: 0x01010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202
```

Calldata:

```
0x83bd37f90001a0b86991c6218b36c1d19d4a2e9eb0ce3606eb480007043b9aca0008058d15e176280000028f5c0001e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e000000000000000000201010101010101010101010101010101010101010101010101010101010101010202020202020202020202020202020202020202020202020202020202020202
```

Expected display:

```
Rejected: no case for value 0x07
```
