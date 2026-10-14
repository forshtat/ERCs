# Reward Vault test vectors

A direct call to the illustrative contract that `TieredExecutor` routes to.

```solidity
function grantReward(address to, uint256 amount) external;
```

Descriptor: [`example-reward-vault.json`](./example-reward-vault.json)

All vectors are sent by `0x1111111111111111111111111111111111111111` to `0x0000000000000000000000000000000000001003` on Ethereum.

## Grant a reward

Arguments:

```
to: 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce
amount: 300000000000000000
```

Calldata:

```
0xa3dc529f000000000000000000000000a11cea11cea11cea11cea11cea11cea11cea11ce0000000000000000000000000000000000000000000000000429d069189e0000
```

Expected display:

```
Intent: Grant 0.3 ETH reward to 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce
Recipient: 0xA11cea11CEA11CEA11cEa11CeA11ceA11CEA11Ce
Amount: 0.3 ETH
```
