# ERC-0000 `customEncoding`: review of weak spots

Scope: `ERCS/erc-0000.md` at `a5fcfc7`, its schema (`erc7730-non-abi-dispatch.schema.json`) and every `example-*.json` file.
Line references (`L123`) point to `ERCS/erc-0000.md`.
Every claim about a deployed contract was checked against that contract's published source. Sources are listed under each item.

The review has four parts:

1. Real, deployed contracts that the syntax cannot describe
2. Errors in the spec's own examples
3. Behaviour the syntax leaves undefined or ambiguous
4. A short list of the additions that would close most of the gaps

---

## 1. Real contracts the syntax cannot describe

Ordered from most to least convincing.

### 1.1 Odos Router V2: `swapCompact()`, the default path of the Odos API

`swapCompact()` takes no ABI arguments. Everything after the selector is a hand-packed stream ([`OdosRouterV2.sol`](https://github.com/odos-xyz/odos-router-v2/blob/main/contracts/OdosRouterV2.sol), `swapCompact`).
`@.data` plus `offset: 4` gets you into the stream, as the LI.FI example does. After that, at least four independent features are missing:

| Calldata element | How Odos encodes it | Why it cannot be described |
|---|---|---|
| Token addresses (in, out, executor, input receiver, output receiver) | 2-byte tag: `0x0000` → zero address (2 bytes), `0x0001` → 20-byte address follows (22 bytes), anything else → `addressList[tag-2]` **read from contract storage** | An inline `switch` handles the first two cases. The `$default` case needs an on-chain storage lookup, so the wallet cannot show which token the user is selling. |
| `inputAmount`, `outputQuote` | 1-byte length `n` (0–32), then an `n`-byte big-endian integer; `n = 0` means "whole balance" | `uint.bytes` must be a literal. There is no variable-width integer, and a `bytes lengthFrom` value cannot be read back as a number. |
| Minimum output (the field that matters for safety) | not in calldata: `outputQuote * (0xFFFFFF - slippage) / 0xFFFFFF` | The only safety-relevant amount has to be computed. The syntax has no arithmetic. |
| `pathDefinition` | 1-byte count `k`, then `k * 32` bytes | `lengthFrom` cannot scale a value. |

Receivers equal to zero mean "executor" and "`msg.sender`". A `switch` on zero with a label can show that, but only once the tag problem above is solved.

### 1.2 Aave V3 `L2Pool` on Arbitrum and Optimism, sent by the official Aave UI

`supply(bytes32)`, `withdraw(bytes32)`, `borrow(bytes32)`, `repay(bytes32)`, `liquidationCall(bytes32,bytes32)` and the other `L2Pool` functions pack their arguments into `bytes32` words ([`CalldataLogic.sol`](https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/logic/CalldataLogic.sol)).
The Aave interface sends these optimised calls on Arbitrum and Optimism: `optimizedPath()` in [`src/utils/utils.ts`](https://github.com/aave/interface/blob/main/src/utils/utils.ts).

- A `bitfield` can describe the bit layout: `assetId = bits[15:0]`, `amount = bits[143:16]`, `referralCode = bits[159:144]`.
- `assetId` is an index into `reservesList`, **a storage mapping**. Without it the wallet cannot name the asset or apply `tokenAmount`.
- The only workaround is a `switch` with one case per reserve, each with a hard-coded `token`. That descriptor goes stale whenever governance lists a new reserve, and it differs on every chain.
- `amount == type(uint128).max` is a sentinel meaning `type(uint256).max` ("everything"). A `switch` can express it.
- The contract masks its fields (`receiveAToken := and(shr(128, args2), 0x1)`), so it ignores set bits outside them. A wallet that decodes the same bits has no rule telling it whether to show, ignore or reject them (see 3.5).

### 1.3 1inch Limit Order Protocol v4 (inside AggregationRouterV6): `fillOrderArgs` / `fillContractOrderArgs`

The layout of `bytes args` is set by bits of **a different ABI parameter**, `takerTraits` ([`TakerTraitsLib.sol`](https://github.com/1inch/limit-order-protocol/blob/master/contracts/libraries/TakerTraitsLib.sol), `OrderMixin._parseArgs`):

```
if takerTraits bit 251:  target = args[0:20]  else target = msg.sender   // who receives the maker asset
extension   = next takerTraits[247:224] bytes
interaction = next takerTraits[223:200] bytes
```

- **The presence of a field depends on a flag elsewhere.** `target`, the recipient, is present only if bit 251 is set. The syntax has no optional or conditional entry. A field-level `switch` on `takerTraits` with two complete layouts can approximate it, but that multiplies with every further flag.
- **A length comes from outside the buffer.** `lengthFrom` and `countFrom` may only name "a preceding sibling entry of the same `object`" (L87), not a bit range of another argument.
- **`extension` uses an offset table** ([`OffsetsLib.sol`](https://github.com/1inch/limit-order-protocol/blob/master/contracts/libraries/OffsetsLib.sol)). The first 32 bytes hold eight cumulative `uint32` end-offsets, with field 0 in the *least* significant bits. Field *i* is `concat[end[i-1] : end[i]]`. Its length is a difference of two decoded values. Expressing it would need arithmetic and reads at absolute positions.

### 1.4 LayerZero V2 OFT `send`, including all of Stargate V2

`SendParam.extraOptions` uses "type 3" options, a sequence of TLV records ([`OptionsBuilder.addExecutorOption`](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/oapp/contracts/oapp/libs/OptionsBuilder.sol), [`ExecutorOptions.sol`](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/messagelib/contracts/libs/ExecutorOptions.sol)):

```
0x0003 | { workerId u8 | size u16 | optionType u8 | option[size-1] }*
         size = option.length + 1   // "+1 for optionType"
lzReceive option: gas u128 [| value u128]   // 16 or 32 bytes, chosen by size
```

- **The length is off by one.** The payload length is `size - 1`, and `lengthFrom` cannot subtract.
- **There are no bounded sub-buffers.** Even with the right length, the syntax cannot say "these `size-1` bytes are themselves an `object`". A `bytes` node and an `object` entry cannot carry a nested `customEncoding`. Only `format: "calldata"` can interpret a sized region, which means length-delimited records (TLV) cannot be described at all.
- **A field's presence depends on the buffer length**: `value` exists only when the option is 32 bytes.

Stargate V2 adds a second gap. `SendParam.oftCmd` chooses "taxi" (immediate) or "bus" (batched, delayed) by **its length alone**: `_isTaxiMode` returns `_oftCmd.length == 0` ([`StargateBase.sol`](https://github.com/stargate-protocol/stargate-v2/blob/main/packages/stg-evm-v2/src/StargateBase.sol)). A `switch` cannot dispatch on a length, and paths have no `.length`.

### 1.5 Polygon PoS `RootChainManager.exit(bytes)`, the call that finishes every Polygon→Ethereum withdrawal

`inputData` is RLP ([`RootChainManager.sol`](https://github.com/maticnetwork/pos-portal/blob/master/contracts/root/RootChainManager/RootChainManager.sol), [`ExitPayloadReader.sol`](https://github.com/maticnetwork/pos-portal/blob/master/contracts/lib/ExitPayloadReader.sol)). It holds a list whose items include an EIP-2718 typed receipt, which holds a log, which holds the token and amount being withdrawn.

- Each RLP item's kind and length come from its prefix byte, by **range**: `0x00–0x7f` is a single byte, `0x80–0xb7` a short string (`len = p - 0x80`), `0xb8–0xbf` a long string (length-of-length), `0xc0–0xff` a list. Matching a range of prefix values, reading the length from the tag byte itself, and length-of-length are all missing.
- The root token comes from `childToRootToken[log.emitter]`, another storage lookup.

### 1.6 Socket / Bungee gateway: fallback dispatch through storage

The `fallback()` reads the first 4 bytes as a `routeId`, finds `addressAt(routeId)`, and **`DELEGATECALL`s `msg.data[4:]`** to that route ([`SocketGateway.sol`](https://github.com/SocketDotTech/bungee-contracts-public/blob/main/src/SocketGateway.sol)). Ids below 385 are hard-coded in bytecode. Higher ids come from the `routes` storage mapping, which the owner can extend and disable.

`$fallback`, a `switch` on `@.data.[0:4]` and `format: "calldata"` with a constant `callee` and `operation: "DELEGATECALL"` can describe it, **but only by listing every route**. That list goes stale when routes are added or disabled. Socket's response to its January 2024 incident was to disable the affected route.

### 1.7 Describable only partly, or only by copy-paste

- **Universal Router `EXECUTE_SUB_PLAN` (`0x21`) is recursive.** Its input is `abi.encode(bytes commands, bytes[] inputs)`, the same shape as the top-level call ([`Dispatcher.sol`](https://github.com/Uniswap/universal-router/blob/main/contracts/base/Dispatcher.sol)). The syntax has no named layouts and no `$ref` inside `customEncoding`, so a descriptor can only repeat the whole `cases` table, to a fixed depth.
- **Universal Router `V4_SWAP` (`0x10`) and v4 `PositionManager.modifyLiquidities(bytes unlockData, uint256)`.** `unlockData` is `abi.encode(bytes actions, bytes[] params)`, and `params[j]` is dispatched by `actions[j]`. Describing it needs:
  - ABI decoding of a `bytes` value, which no `customEncoding` node does (only `switch` cases do, so authors would need a `$default`-only `switch` as a workaround);
  - `$index` nested inside another `$index` (undefined, see 3.2);
  - both tuple encodings from 2.1 *inside one contract*: `SWAP_EXACT_IN_SINGLE` params are `abi.encode(struct)`, while `SETTLE_ALL` params are `abi.encode(currency, amount)` ([`CalldataDecoder.sol`](https://github.com/Uniswap/v4-periphery/blob/main/src/libraries/CalldataDecoder.sol)).
- **Balancer ComposableStable joins.** `request.assets` *includes* the BPT token, but `userData.amountsIn` *excludes* it (`_dropBptItem`, [`ComposableStablePool.sol`](https://github.com/balancer/balancer-v2-monorepo/blob/master/pkg/pool-stable/contracts/ComposableStablePool.sol)). ERC-7730's parallel-array iteration (`tokenPath: "#.request.assets[]"`) therefore pairs every amount with the wrong token. That is presumably why the example covers only `WEIGHTED` joins. Supporting it needs index remapping, at least "skip index *k*".
- **Wormhole Token Bridge amounts.** They are normalised to 8 decimals, and the local token is found in storage (`wrappedAsset(chain, addr)`). The example falls back to `"format": "raw"`. Showing a correct amount needs scaling and a lookup.
- **`bytes32` addresses that depend on the chain** (Wormhole, Across v3.5+ `deposit`, LayerZero `to`). An EVM address is the low 20 bytes. A Solana address is all 32 bytes, in base58. `switch` + `offset: 12` + `address` covers EVM, but nothing renders a non-EVM address, and skipped high bytes are never checked to be zero (3.5).

**Common theme.** Every case in 1.1–1.6 needs one or more of: **state lookups, arithmetic on lengths and values, bounded sub-buffers, conditional or optional entries, range or length dispatch, and recursion.** The commit history shows a deleted `feature-stateref-based-dispatch.md`. If state lookups are out of scope on purpose, the Rationale should say so and name these contracts as known exclusions.

---

## 2. Errors in the spec's own examples

### 2.1 The tuple-signature case key means two different encodings (high severity)

The same syntax, `"(T1 a,T2 b,...)": {fields}`, is used for both of these, and they are different byte layouts whenever the tuple contains a dynamic member:

| Example | What the contract actually does |
|---|---|
| Universal Router: `"(address recipient,uint256 amountIn,uint256 amountOutMinimum,bytes path,bool payerIsUser)"` | `abi.decode(inputs, (address,uint256,uint256,bytes,bool))`, a **parameter list** |
| Across: `"(address inputToken,...,bytes message)"` | `abi.decode(orderData, (AcrossOrderData))`, a **single struct** ([source](https://github.com/across-protocol/contracts/blob/99365045c9dee9ed392d4027a4892face612d8e3/contracts/erc7683/ERC7683OrderDepositor.sol#L282), the last version before the contracts were removed in 2026) |

Encoding `(address, uint256, bytes)` both ways:

```
parameter list (160 bytes)        single struct (192 bytes)
 0000..1111111111111111..11        0000..0000000000000000..20   <- extra head offset
 0000..0000000000000000..05        0000..1111111111111111..11
 0000..0000000000000000..60        0000..0000000000000000..05
 0000..0000000000000000..01        0000..0000000000000000..60
 ab00..0000000000000000..00        0000..0000000000000000..01
                                   ab00..0000000000000000..00
```

Whichever rule a wallet picks, one of the two examples decodes as garbage. For Across under the parameter-list rule, `inputToken` reads as `0x…0020` and `inputAmount` reads as the token address. The spec should define the shorthand as `abi.decode(payload, (T1,T2,…))`, i.e. a parameter list, and require a single struct to be written as one named member, `"((address inputToken,…,bytes message) order)"`. Then fix the Across example.

The `(...)[]` form in the ERC-7579 example (`abi.encode(Execution[])`) is a third case: one unnamed parameter of array type. It works, but only because of a convention nobody has written down.

The Across example's case key **is** correct: it equals `keccak256` of the `AcrossOrderData(...)` type string with `depositNonce`, which I checked.

### 2.2 Balancer library example

- **The tuple members have no names.** The keys use `(address[],uint256[],bytes,bool) request` and `(uint256,uint256)[] outputReferences`, yet the fields use `request.assets[]`, `request.maxAmountsIn[]`, `request.userData`, `outputReferences[].key`. ERC-7730 says paths "MUST all use the names from the key", so none of these paths resolve.
- **The chained-reference check is on the wrong field.** Balancer substitutes chained references into `amountsIn` for `EXACT_TOKENS_IN_FOR_BPT_OUT`, not into `minBPTAmountOut` (`_doWeightedExactTokensInForBPTOutReplacements`, [`VaultActions.sol`](https://github.com/balancer/balancer-v2-monorepo/blob/master/pkg/standalone-utils/contracts/relayer/VaultActions.sol)). The example applies the `0xba1…` switch to `minBptAmountOut`, which is never substituted, and displays `amountsIn[]` with a plain `tokenAmount`. A chained reference in `amountsIn` would therefore show as an amount of about 8.4·10⁷⁶ base units.
- **Two switches in the spec contradict each other.** `request.userData` uses a field-level `switch` whose `expression` is a *node* (`{"type":"uint","bytes":32}`), and its case `(uint8 joinKind,uint256[] amountsIn,…)` decodes from byte 0, so the expression **did not consume** the tag. In the Wormhole example, the inline `switch` expression `{"type":"uint","bytes":1}` **does consume** the tag: case `0x01` starts at `amount`. One of the two is wrong under any single rule, and the text defines neither (3.2).
- **`0xba10…` vs `0xba11…` is collapsed.** The mask `0xfff…` matches Balancer's `_isChainedReference`, but the fourth nibble separates temporary (`0xba10`) from read-only (`0xba11`) references, and the example does not show the difference. Minor.

### 2.3 Labels that display nothing

L267 says "An entry is displayed if and only if it carries `label` or `format` inline, or a display field addresses it". Under that rule:

- `example-uniswap-v4-initialize.json`: none of the 14 `bitranges` has a label, and no field addresses them, so the "Hook permissions" field displays nothing. The sample in the spec text at L217–223 labels three of them.
- `example-erc7579-execute.json`: the "Mode" field displays nothing, so the security-relevant `execType` is hidden. `0x01` means "try": failing calls are silently ignored.

The spec also never says what the parent field's own `label` renders as: a heading, a group, or nothing (3.4).

### 2.4 Universal Router: the mask and inputs depend on the version

`COMMAND_TYPE_MASK` is `0x3f` in UR **2.0.0**, the version at `0x66a9…` that the example targets, and `0x7f` from **2.1.x** onwards (2.1.1 and 2.1.2 are also deployed: [`deploy-addresses/mainnet.json`](https://github.com/Uniswap/universal-router/blob/main/deploy-addresses/mainnet.json)). 2.1 also added a sixth input to `V3_SWAP_EXACT_IN`, `uint256[] maxHopSlippage`.

- The text at L571 states "low 6 bits" as a general fact about Universal Router. It is true of one version only.
- If the 5-member key from 2.0.0 is applied to 2.1 calldata, the parameter-list decode succeeds and **silently drops the slippage array**. This is a concrete instance of the trailing-data question in 3.1.

### 2.5 Smaller example issues

- `example-safe-multisend.json` lists **MultiSendCallOnly**, which reverts on `operation == 1`, yet maps `0x01` to `DELEGATECALL`. The `"$default": "CALL"` also displays operation values ≥ 2 as `CALL`, but both MultiSend variants revert on them (their `switch` has no default, so `success` stays 0). `$default` should be `reject`.
- Path notation does not follow ERC-7730. 7730 says "Paths MUST use the dot notation, including for slice and array selectors (`array_name.[index]`)". The examples write `inputs[]`, `data[]`, `commands[$index]`, `request.maxAmountsIn[]`, `outputReferences[].key`, while the spec text writes `transactions.[].to` and `~.[].callData`.
- Case keys are written two ways: `"1"` and `"2"` in `example-tiered-executor.json`, `"0x00"` everywhere else (3.2).
- Every example's `$schema` points to `assets/eip-7730/erc7730-non-abi-dispatch.schema.json`, but the file is in `assets/erc-0000/`.

---

## 3. Undefined or ambiguous behaviour

### 3.1 The buffer model

1. **What bytes does a `customEncoding` on a non-`bytes` argument see?** The examples suggest the native width: `bytes: 20` on an `address`, `bytes: 32` on a `uint256`. The spec never says so. Questions it leaves open:
   - Does a `uint24` give 3 bytes or a 32-byte word?
   - Is an `int24` sign-extended?
   - Is a `bool` 1 byte?
   - What about a tuple, or `string`?
2. **Running out of bytes.** Only `string` defines a failure fallback (L297). A truncated `object`, an `address` with 7 bytes left, or a `countFrom` larger than the data allows has no defined result: reject, show hex, or partial display.
3. **Bytes left over.** The spec does not say whether unconsumed trailing bytes are an error. Contracts usually ignore them (Odos ignores everything after `pathDefinition`; 2.4 shows the Universal Router case), so they can carry data the user never sees. Recommendation: the top-level node MUST consume the whole buffer exactly unless it ends in `toEnd`.
4. **A count-less `sequence` (L67) runs "until the input bytes are exhausted".**
   - The spec does not say what happens to a partial last element. (MultiSend reverts on one, so a wallet should too.)
   - It does not require such a `sequence` to be the last entry of its `object`, as it does for `toEnd` (L163).
   - Inside another count-less `sequence`, the outer sequence always has exactly one element.
5. **`toEnd` "MUST be the last entry of its `object`" (L163).** "Buffer" is never defined. An `object` has no length of its own, so `toEnd` inside a nested `object` that has later siblings in its parent consumes the parent's bytes. The rule needs to apply to every enclosing level, or the spec needs bounded sub-buffers (see 4).
6. **L60 says "Every `customEncoding` node consumes a well-defined, computable number of bytes".** This is false in three places:
   - A tuple-shorthand case decodes ABI data, whose heads can point anywhere, including overlapping or out-of-order tails.
   - A count-less `sequence` consumes whatever remains.
   - An inline `switch` whose case is `{format}`, `{label}` or `reject` consumes the expression and then nothing that is defined.

### 3.2 `switch`

1. **There are four forms and no shared rule for consuming bytes:**
   - (a) a field-level `switch` with a path expression: the payload is the field value, nothing is consumed;
   - (b) a field-level `switch` with a **node** expression: the schema allows it, the text never mentions it, and the Balancer example relies on it with peek semantics;
   - (c) an inline `switch` node: the Wormhole example consumes the tag;
   - (d) a top-level `switch` with a node expression: which buffer does it read, `@.data` or the arguments?

   Each form needs a stated rule. "Consume" and "peek" also both need to exist, because some tags are part of the payload (an RLP prefix, the protocol bits in the top of 1inch's `Address` words).
2. **`"reject"` is used in every example but defined nowhere.** Does the wallet refuse to sign, show a blind-signing warning, or show raw data? What happens when `cases` has no `$default` and nothing matches?
3. **Case keys are not canonical.** Are `"0x1"`, `"0x01"`, `"1"` and `"0X01"` equal? Is a key compared as a **number** or as **bytes**? For a `bytes32` expression (the Compound `actions`), `"0x01"` matches `0x0000…01` numerically but `0x0100…00` as left-aligned bytes, which is how Solidity treats `bytes32`. Two keys that compare equal also have no tie-break.
4. **`mask` has no alignment rule.** A mask shorter than the value (`"0xff"` on a `bytes32`) could align at the low end (numeric) or the high end (bytes). It is also unclear whether `$default: {format: "tokenAmount"}` formats the masked value or the original. The examples need the original.
5. **`mask` appears in some schemas and not others.** L381 says `mask` "is available on any `switch` expression". The schema allows it on field-level `{path, mask}` and on `uint` nodes, but **not** on the top-level `switch` `{path}` form or on the `operation` expression. It also allows `mask` on *any* `uint` node, for example an `object` entry, where it has no defined meaning.
6. **Only exact matching exists.** There are no ranges (RLP prefixes, `amount >= threshold`), no matching on length (Stargate `oftCmd`), and no matching on strings. For strings: is the key `"AAVE-V3-A"` text or hex? Instadapp's `cast(string[] targetNames, …)` dispatches on connector names.
7. **`$index` (L498) is underspecified.**
   - The text says it refers to a `sequence` element's position, but the example uses it on an ABI array (`inputs[]`).
   - When `$index` is nested (1.7), it is unclear which loop it refers to.
   - The spec does not say what happens when `commands` and `inputs` have different lengths (the Universal Router reverts with `LengthMismatch`) or when an index is out of range.
   - It is not part of ERC-7730's path grammar, which allows only name, index and slice selectors.
   - L516 applies `commands[$index]` to `commands`, a `bytes` value. It is unclear whether that indexes raw bytes or the decoded `sequence`.
8. **`payloadFrom` is one sentence long (L384)**, with no example and no defined meaning beyond "in place of `$index`".
9. **`intent` means something else inside a case.** `{label, intent: "info"|"warning"}` uses `intent` as a severity level, while 7730's `intent` describes what the transaction does.
10. **The tuple-shorthand case accepts `intent` but not `interpolatedIntent`**, while top-level `switch` cases accept both. Since L266 forbids paths through a `switch`, the outer `interpolatedIntent` cannot mention anything decoded inside a case. A Wormhole transfer intent cannot say "Receive {amount}".

### 3.3 References and scope

1. **`countFrom` and `lengthFrom` can only name a preceding sibling (L87).** They cannot name:
   - a field in a parent `object`, such as a header that holds the counts of several later arrays;
   - a `bitranges` entry of a sibling `bitfield`;
   - an ABI argument (1inch `takerTraits`);
   - a field nested inside an earlier sibling.

   There is also no path syntax for any of these.
2. **No arithmetic.** The real cases need `value - 1` (LayerZero), `value * 32` (Odos) and `end - begin` (1inch).
3. **`~` has no parent.** Inside a `sequence` element, or a `switch` case inside an `object`, the outer structure cannot be reached, so the Wormhole payload cannot refer to `emitterChainId`. The spec also does not say what `~` means when the enclosing node is not an `object`, for example a `sequence` of `uint` or a `bitfield`.
4. **Unprefixed paths are ambiguous (L175).** An entry may share its name with a function argument. L175 says the unprefixed path "resolves the same way" (relative). That is a silent behaviour change from 7730 for the same string, and the spec only recommends `~.` instead of requiring it.
5. **Two fields can share a path.** The Uniswap example declares `key.hooks` twice, once with `addressName` and once with `customEncoding`. If two fields on the same path both carry `customEncoding`, nothing decides which one `key.hooks.beforeSwap` refers to.

### 3.4 Display semantics

1. **The spec does not say what the field holding the `customEncoding` displays**: its `label` with raw bytes, a heading over its entries, or nothing (2.3).
2. **`visible` contradicts L267.** `visible` defaults to `always` (L187), yet an entry without `label` or `format` is not displayed. The `numSignatures` example adds `"visible": "never"` to an entry that would be hidden anyway.
3. **There is no display rule for a `sequence` or `object` as a whole.** For example, how is "Commands" (a `sequence` of `uint`) shown? Does 7730's `separator` apply?
4. **`interpolatedIntent` over a `sequence` entry** (`{transactions.[].to}`) is undefined.

### 3.5 Types

1. **There is no signed `int` node.** The only way to read a packed signed value is a `bitfield` with one signed range covering every bit.
2. **`bool` is unspecified**: its width, and whether values other than 0 and 1 are an error or `true`. Contracts disagree: ABI decoding reverts on them, assembly code treats any non-zero value as true.
3. **`address` is a fixed 20 bytes.** A 32-byte word needs `offset: 12`, and **skipped bytes are never validated** (L168). A recipient word with non-zero high bytes then displays as a clean address. That is harmless when the contract masks those bytes, but nothing makes the descriptor say which case applies. Suggested fix: allow `offset` to require zero bytes, or allow `mustMatch` on skipped bytes.
4. **Bit ranges can only produce integers.** 1inch's `Address` type keeps flags in the top bits and the address in the low 160 bits. Fields like that need a bit range that yields an `address`.
5. **Dirty bits outside the declared ranges** of a `bitfield` (Aave) are ignored without any statement that they are.

### 3.6 `string`

The deny-list at L285–294 misses many invisible or layout-breaking code points:

- U+00AD soft hyphen
- U+034F combining grapheme joiner
- U+115F, U+1160, U+3164, U+FFA0 Hangul fillers (these render blank)
- U+180E
- U+2060–U+2064 (word joiner, invisible operators)
- U+206A–U+206F
- U+FFF9–U+FFFB
- U+FE00–U+FE0F and U+E0100–U+E01EF variation selectors
- **U+E0000–U+E007F tag characters**, the known "ASCII smuggling" vector
- U+2028 and U+2029 line and paragraph separators
- unlimited combining marks (Zalgo text)

A deny-list will always lag Unicode. An allow-list is safer, or at least a rule by General Category: reject `Cc`, `Cf`, `Zl`, `Zp`, `Co`, `Cn`, `Cs`, plus the blank-rendering `Lo` fillers. Also unaddressed:

- `string` has no maximum length.
- NFC results depend on the Unicode version, which the spec does not fix.
- Runs of ordinary spaces can push text past a screen's truncation point.

### 3.7 `interaction` and `operation`

1. **`interaction.to`** is a bare string, while `args` use `{path}` objects. It is unclear whether `"to": "0xA0b8…"` is a literal or a path.
2. **`interaction` cannot express `value` or `operation`**, even though L424 mentions `delegatecall` and `staticcall`.
3. **The `operation` list** has no `STATICCALL`. `CREATE` and `CREATE2` combined with `format: "calldata"` have no meaning: there is init code instead of calldata, no callee and no salt.
4. **`DELEGATECALL` is a security issue the spec does not mention.** The inner descriptor is written for the callee's own context, but the code runs in the *caller's* storage with the caller's `msg.sender`. Wallets should only use descriptors marked as safe for delegatecall, or show a strong warning (MultiSend, Socket routes, Balancer relayer).
5. **`interaction` has no display rule.** It has no `label`, and the spec does not say how the target's `intent` combines with the outer `intent`.

### 3.8 `$fallback`

1. **"Selected whenever calldata does not correspond to any selector entry in the file" (L457) is unsafe.** Descriptors usually cover a subset of a contract's functions (the LI.FI Diamond file does). With `$fallback` present, any real function the file does not list is parsed by the fallback layout and displayed wrongly. The condition has to be "the contract has no function with this selector". A wallet cannot know that, so `$fallback` should require the descriptor to declare the contract's complete selector set, or be limited to contracts that declare they have no selector dispatch.
2. **Empty calldata (`receive`) and calldata shorter than 4 bytes** are not addressed.
3. **`@.data` is defined only in the `$fallback` section (L462)**, but the LI.FI example uses it under an ordinary selector key.

### 3.9 Schema and text disagree

- "`customEncoding` MUST NOT combine with `format`" and the mutual exclusion of `interaction` with both exist **only in schema comments**. The comments cite "### customEncoding", which says nothing of the kind.
- The schema allows `switch` + `customEncoding`, `switch` + `format`, and `switch` + `interaction` on the same field. None of these combinations is defined.
- The schema's comment notes that `customEncoding`, `switch` and `interaction` also become valid inside `fieldGroup` and `reference` `fields` as a side effect. No example covers them.
- A `bits` range is not required to have `hi >= lo`.

### 3.10 Security Considerations (currently "TBD")

At minimum:

- limits on recursion depth, `count`/`countFrom` (a `uint256` count is a DoS), element count and total display size;
- recursion through `format: "calldata"`, such as MultiSend calling MultiSend, or a Socket route;
- a trailing-data policy (3.1.3);
- dirty and skipped bits (3.5);
- delegatecall context (3.7.4);
- the `$fallback` selector problem (3.8.1);
- the string homoglyph and invisible-character limits (3.6);
- descriptors going stale after contract upgrades, which 2.4 shows already happening.

---

## 4. Additions that would close most gaps

| Addition | Fixes |
|---|---|
| **Bounded sub-buffer**: let `bytes` (and an `object` entry) carry a nested `customEncoding` that must consume exactly its bytes | LayerZero TLV, length-prefixed structs, a correct `toEnd` scope |
| **`abi` node** (`{"type":"abi","types":"(bytes actions,bytes[] params)"}`), with the parameter-list rule stated explicitly | v4 `PositionManager`, `V4_SWAP`, `EXECUTE_SUB_PLAN`, the tuple ambiguity, ABI in a packed buffer |
| **Small integer expressions** for `length`/`count`/`offset` (`+ - * /`, a path to a sibling, parent or argument) | LayerZero `size-1`, Odos `n*32`, 1inch offsets |
| **`varuint`** (length-prefixed big-endian integer) and **`int`** | Odos amounts, packed signed values |
| **Conditional entries** (`"when": {path, mask, equals}`) | 1inch `target`, LayerZero `value`, flag-gated fields |
| **`peek: true`** on a `switch` expression; **range keys** (`"0x80..0xb7"`); a **`$length` switch** | RLP, 1inch `Address`, Stargate `oftCmd`, Balancer `userData` |
| **Named layouts with `$ref` and a depth limit** | `EXECUTE_SUB_PLAN`, nested `$index`, `predicate` trees |
| **Parent scope** (`~~.` or `^.`) and a **defined `$index` stack** | Wormhole payload, nested router actions |
| **A written policy on state lookups**: out of scope with named exclusions, or an `eth_call`-style `stateRef` with a fixed allow-list of view functions | Odos address list, Aave `reservesList`, Polygon `childToRootToken`, Socket `routes`, Wormhole `wrappedAsset` |
