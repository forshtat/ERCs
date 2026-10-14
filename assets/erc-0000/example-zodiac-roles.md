# Zodiac Roles v2 scopeTarget test vectors

Calls to `scopeTarget(bytes32,address)` on a Zodiac Roles v2 module on Ethereum, usually executed by the Safe that owns the module.

```solidity
function scopeTarget(bytes32 roleKey, address targetAddress) external;
```

Descriptor: [`example-zodiac-roles.json`](./example-zodiac-roles.json)

All vectors are sent by `0x1111111111111111111111111111111111111111` to `0x7a6E5D2Fc4a0f4c3fa8D8E1b6e3c2e4f5A6b7c8D` on Ethereum.

## Text role key

Arguments:

```
roleKey: 0x4d414e4147455200000000000000000000000000000000000000000000000000
targetAddress: 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af
```

Calldata:

```
0x0c6c76b84d414e414745520000000000000000000000000000000000000000000000000000000000000000000000000066a9893cc07d91d95644aedd05d03f95e1dba8af
```

Expected display:

```
Intent: Scope 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af for role MANAGER
Role: MANAGER
Target: 0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af
```

## Role key using all 32 bytes

Arguments:

```
roleKey: 0x6162636465666768696a6b6c6d6e6f707172737475767778797a303132333435
targetAddress: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

Calldata:

```
0x0c6c76b86162636465666768696a6b6c6d6e6f707172737475767778797a303132333435000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
```

Expected display:

```
Intent: Scope 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 for role abcdefghijklmnopqrstuvwxyz012345
Role: abcdefghijklmnopqrstuvwxyz012345
Target: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

## Role key that is not valid text

U+202E, a bidirectional override, makes the key show as hex.

Arguments:

```
roleKey: 0x706179e280ae6576696c00000000000000000000000000000000000000000000
targetAddress: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```

Calldata:

```
0x0c6c76b8706179e280ae6576696c00000000000000000000000000000000000000000000000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48
```

Expected display:

```
Intent: Scope 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 for role 0x706179e280ae6576696c00000000000000000000000000000000000000000000
Role: 0x706179e280ae6576696c00000000000000000000000000000000000000000000
Target: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
```
