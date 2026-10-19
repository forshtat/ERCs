# Legacy Token test vectors

A direct call to the illustrative contract that `TieredExecutor` routes to.

```solidity
function creditAccount(uint256 amount, address to) external;
```

Descriptor: [`example-legacy-token.json`](./example-legacy-token.json)

All vectors are sent by `0x1111111111111111111111111111111111111111` to `0x0000000000000000000000000000000000001002` on Ethereum.

## Credit a balance

Arguments:

```
amount: 2000000000000000000
to: 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb
```

Calldata:

```
0x390f514d0000000000000000000000000000000000000000000000001bc16d674ec80000000000000000000000000000b0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb0bb
```

Expected display:

```
Intent: Credit 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb with 2 ETH
Amount: 2 ETH
Recipient: 0xb0bB0bB0Bb0Bb0bB0Bb0bb0bb0bB0BB0Bb0BB0Bb
```
