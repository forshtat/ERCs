---
title: Frame Transaction Alternative Mempools
description: Alternative mempools framework for EIP-8141 Frame Transactions that extend the public mempool with stake and reputation.
author:
discussions-to: https://ethereum-magicians.org/t/PLACEHOLDER
status: Draft
type: Standards Track
category: ERC
created: 2026-09-21
requires: 1153, 7702, 7819, 7843, 7951, 8037, 8141
---

## Abstract

[EIP-8141](./eip-8141.md) defines a new [EIP-2718](./eip-2718.md) transaction type and a set of rules such transactions need to follow in the canonical public mempool.
These canonical mempool rules are chosen to be relatively simple and universal in a way that enables a number of high priority use cases.
Other rulesets can serve use cases made impossible by the canonical mempool rules, but without a public mempool such transactions require a private submission mechanisms.
This document defines a framework for alternative mempools with customized validation rulesets for [EIP-8141](./eip-8141.md) Frame Transactions.
The rulesets define which transactions a node may admit to the mempool, which it rejects, and how it tracks the entities that form a transaction's validation process.

This document also defines the **standard alternative mempool**, a default ruleset for a permissionless and decentralized public Frame Trnansactions mempool that is less restrictive than the canonical one.

## Motivation

A frame transaction replaces a hard-coded signature check with EVM code that runs during a *validation prefix*. Before a mempool node relays such a transaction, it must execute the entire validation prefix code. If the prefix depends on mutable state that anyone can change, a single state change can invalidate many pending transactions at once, and a node that spends resources on those transactions is never paid. This is the *mass invalidation attack*. Mempools must put in place carefully designed sets of rules to bound this threat.

[ERC-4337](./eip-4337.md) relies on rules defined in [ERC-7562](./eip-7562.md) to solve the same problem for `UserOperation`s.
Frame Transactions differ from `UserOperation`s in ways that make defining a shared rule set inconvenient.
This document defines the Frame Transaction specific mempool rules in a way that maintains a full backward compatibility with use cases that existed in ERC-4337, like autonomous [ERC-20](./erc-20.md) Token Paymasters, privacy pool withdrawals an more.

## Specification

### Relationship to Other Mempools

This document addresses three distinct named rulesets for Frame Transaction mempools:

1. The **canonical public mempool**, as defined by EIP-8141 in the [Mempool](./eip-8141.md#Mempool) section.
2. The **standard alternative mempool**, as defined by this document.
3. The **non-standard alternative mempools**, which are defined by third party mempool operators as defined in [Alternative Mempools](#alternative-mempools) section.

A transaction that violates a canonical public mempool rule MUST NOT be propagated over the public mempool, as EIP-8141 requires. It may only be propagated over the appropriate alternative mempool's own transport if it satisfies its rules. One transaction may be propagated over multiple alternative mempools if it satisfies all of their rules.

### Rule Types

Pulbic transaction mempools are shared by multiple nodes in a peer-to-peer network, while each node maintains its own view of the mempool and participant reputations at all times.
Therefore, there are two types of validation rule: **network-wide rules** and **local node rules**.

A violation of any rule by a frame transaction results in the transaction being dropped from the mempool and excluded from any block the node builds.

A peer-to-peer mempool networks rely on participant reputations to limit the threat of mass transaction invalidation. A **network-wide rule** is a rule whose violation by a transaction damages the reputation of the peer that sent that transaction into the standard mempool. A peer with critically low standing is treated as a **spammer** according to the  [Propagation Rules](#propagation-propagation).

A **local rule** depends on a node's own mempool contents and opinions on entities' reputations. Different nodes may hold different mempool contents, so no consensus is possible and peers are never penalised for a local rule violation. Local rules are marked *(Local)* and all other rule are network-wide.

### Constants

| Name | Value | Description |
|---|---|---|
| `MAX_VERIFY_GAS` | `100_000` | Maximum gas a node expends validating signatures and simulating the validation prefix. Same value as EIP-8141. |
| `MAX_VERIFY_STATE_GAS` | `500_000` | Maximum state gas ([EIP-8037](./eip-8037.md)) budgeted across the validation prefix. Same value as EIP-8141. |
| `MIN_UNSTAKE_DELAY` | `86400` | One day. A withdrawal delay long enough to deter most Sybil attacks. |
| `MIN_STAKE_VALUE` | per-chain | A non-trivial but not excessive amount, roughly the equivalent of USD 1000 in the native token. |
| `SAME_SENDER_MEMPOOL_COUNT` | `1` | Maximum pending transactions from one sender. |
| `SAME_UNSTAKED_ENTITY_MEMPOOL_COUNT` | `10` | Base number of pending transactions that may reference the same unstaked sponsoring payer. |
| `THROTTLED_ENTITY_MEMPOOL_COUNT` | `4` | Pending transactions allowed for a throttled entity. |
| `THROTTLED_ENTITY_LIVE_BLOCKS` | `10` | Blocks a transaction referencing a throttled entity may stay in the mempool. |
| `THROTTLED_ENTITY_BLOCK_COUNT` | `4` | Transactions referencing a throttled entity that a node may include in one block it builds. |
| `MIN_INCLUSION_RATE_DENOMINATOR` | `10` | Denominator in the reputation formula. |
| `THROTTLING_SLACK` | `10` | Lets an entity legitimately fail some transactions without being throttled. |
| `BAN_SLACK` | `50` | Lets a throttled entity fail some transactions without being banned. |
| `BAN_TXS_SEEN_PENALTY` | `10000` | Value written into an entity's `seen` counter to ban it. |
| `MAX_TXS_ALLOWED_UNSTAKED_ENTITY` | `10000` | Upper bound on `included` when computing the allowance of an unstaked sponsoring payer. |
| `STAKING_REGISTRY_ADDRESS` | per-chain | Address of the Staking Registry contract (see [Appendix A](#appendix-a-staking-registry-contract)). |

### Definitions

1. **Validation prefix**: the shortest prefix of a transaction's frames whose successful execution sets `payer`, as defined by EIP-8141. Frames after the prefix belong to the **execution body** of the Frame Transaction and are largely outside this document's scope.
2. **Validation frame**: a frame in the validation prefix.
3. **Frame subclasses**: a heuristic classification of a call frame within a Frame Transactgion based on its role and behaviour.
   The EIP-8141 mode subclassifications defines the following subclasses: `self_verify`, `only_verify`, `pay`, `expiry_verify` and `deploy`; the `pre_verify` subclass is additionally defined in this document.
4. **Entity**: an address that a validation frame executes as, attributed by role:
    - The **sender** is `tx.sender`. It runs the `self_verify` or `only_verify` frame.
    - The **payer** is the resolved target of the frame that calls `APPROVE` with a payment scope. It runs the `pay` frame or the `self_verify` frame.
    - The **factory** is the resolved target of the `deploy` frame.

   Every validation frame is attributed to exactly one entity. An `expiry_verify` frame is attributed to no entity as its code is protocol-defined.
5. **Default-code entity**: an entity whose account has the empty code hash and therefore executes EIP-8141's default code. It has no bytecode to trace, is never staked, and is exempt from the opcode, call and storage rules.
6. **Staked entity**: an entity that has a stake of at least `MIN_STAKE_VALUE` and an unstake delay of at least `MIN_UNSTAKE_DELAY`, as reported by the **Staking Registry** smart contract, and whose stake is not being withdrawn.
7. **Associated storage**: a storage slot of any contract is *associated* with address `A` according to the [Associated Storage Rules](TODO?)
9. **Canonical paymaster**: a contract whose runtime code exactly matches the canonical paymaster implementation defined by EIP-8141.
10. **Admission validation**: the simulation a node performs before it first accepts a transaction.
11. **Revalidation**: a re-simulation of a pending transaction against a newer head or a candidate block, as described in [Replacement, Eviction and Revalidation](#replacement-eviction-and-revalidation-lifecycle).
12. **Spammer**: a peer that attempts to exhaust the mempool network by sending a large number of transactions that were never valid. See [PROPAGATION-050](#propagation-propagation).
13. **Mass mempool invalidation** TODO

### Execution Model

`VERIFY` frames run in static mode. Only `APPROVE` may change state or transaction context in them. Storage writes, transient storage writes, logs, contract creation and value-carrying calls are therefore unavailable inside a `VERIFY` frame at the EVM level, regardless of any mempool rule. The non-static frames in the validation prefix are the `deploy` frame defined in EIP-8141 and the newly defined `pre_verify` frame, both of which run in `DEFAULT` mode. Rules in this document that mention writes, contract creation or value calls consequently take effect only in those frames. A failed `DEFAULT`-mode frame does not invalidate a transaction. Only the failure of a `VERIFY` frame does.

### Validation Prefix and Structure (PREFIX)

* **[PREFIX-010]** The validation prefix MUST match one of the following shapes, optionally preceded by a single `expiry_verify` frame. A transaction whose prefix matches none of them MUST be rejected.
    * `[self_verify]`
    * `[deploy, self_verify]`
    * `[only_verify, pay]`
    * `[deploy, only_verify, pay]`

  In every shape, each approving frame (`self_verify`, `only_verify` or `pay`) MAY be immediately preceded by one `pre_verify` frame, as [PREFIX-110] describes.
  TODO expiry frame not mentioned
* **[PREFIX-020]** If a `deploy` frame is present it MUST be the first frame of the prefix, not counting a leading `expiry_verify` frame. There is at most one `deploy` frame.
* **[PREFIX-030]** A `self_verify` or `only_verify` frame MUST run in `VERIFY` mode, MUST target `tx.sender` (explicitly or with a null target), and MUST successfully call `APPROVE` with the scope its `flags` declare: `APPROVE_EXECUTION_AND_PAYMENT` for `self_verify`, `APPROVE_EXECUTION` for `only_verify`. A `pay` frame MUST run in `VERIFY` mode, MUST have `flags` equal to `APPROVE_PAYMENT`, and MUST successfully call `APPROVE(APPROVE_PAYMENT)`.
* **[PREFIX-040]** No frame in the validation prefix may carry `ATOMIC_BATCH_FLAG`.
* **[PREFIX-050]** No `VERIFY` frame may follow the validation prefix. If one did, a failure after the payer had already been committed would invalidate the whole transaction.
* **[PREFIX-060]** A transaction MUST be rejected if, before `payer` is set, any validation frame reverts, or a `self_verify`, `only_verify` or `pay` frame exits without its required `APPROVE`.
* **[PREFIX-070]** If a `deploy` frame is present, its execution MUST result in non-empty code at `tx.sender`, either contract code or an [EIP-7702](./eip-7702.md) delegation indicator. Otherwise the transaction MUST be rejected.
* **[PREFIX-080]** An `expiry_verify` frame MAY appear only as the first frame of the transaction. A node MUST drop a transaction whose `expiry_verify` deadline is earlier than the node's view of the current block timestamp, at any time and not only at admission.
* **[PREFIX-090]** A node SHOULD stop simulating once `payer` is set and the frame that set it has completed successfully.
* **[PREFIX-100]** Three frame kinds have fully protocol-defined behaviour: a frame whose target is a default-code entity, an `expiry_verify` frame running the canonical runtime code at `EXPIRY_VERIFIER`, and a `pay` frame whose target is a canonical paymaster. These frames are admitted by identity and are exempt from the opcode, call and storage rules below. A node MAY evaluate them directly instead of simulating them. It MUST apply the same limits it would apply under simulation, including [BUDGET-010](#budgets-budget) and [SOLVENCY-010](#payer-solvency-solvency).
* **[PREFIX-110]** A `pre_verify` frame is a `DEFAULT`-mode frame whose resolved target is the same as the resolved target of the approving frame (`self_verify`, `only_verify` or `pay`) that immediately follows it. Each approving frame MAY be preceded by at most one `pre_verify` frame. The target of a `pre_verify` frame MUST have deployed code. A `DEFAULT`-mode frame in the validation prefix that is neither the `deploy` frame nor a `pre_verify` frame MUST cause the transaction to be rejected. The first `DEFAULT`-mode frame is a `pre_verify` frame, not the `deploy` frame, if its resolved target equals that of the frame that follows it.
* **[PREFIX-120]** The code of an approving frame that is preceded by a `pre_verify` frame MUST check the status of that `pre_verify` frame before it calls `APPROVE`, using the frame status parameter of `FRAMEPARAM`, and MUST NOT call `APPROVE` if that status is not success. A failed `DEFAULT`-mode frame does not invalidate the transaction, so without this check the approving frame would approve after the writes it depends on had been reverted. A node cannot verify this requirement in general. A node MUST reject at admission a transaction whose `pre_verify` frame does not succeed in simulation ([PREFIX-060]).

### Budgets (BUDGET)

* **[BUDGET-010]** The sum of `limits.execution` across the validation prefix, plus the intrinsic cost of validating `tx.signatures`, MUST NOT exceed `MAX_VERIFY_GAS`.
* **[BUDGET-020]** The sum of `limits.state` across the validation prefix MUST NOT exceed `MAX_VERIFY_STATE_GAS`.

### Signatures (SIGNATURE)

* **[SIGNATURE-010]** Before simulating any frame, a node MUST validate every protocol-validated signature (`SECP256K1`, `P256`) against the transaction's signature hash. It MUST also check every `ARBITRARY` signature for structural validity. A transaction with any malformed or invalid signature MUST be rejected.
* **[SIGNATURE-020]** The bytes of an `ARBITRARY` signature are witness data. They are authenticated only by EVM code running in a frame, so the frame that inspects them is fully subject to the rules below.

### Opcode Rules (OPCODES)

Opcodes that read the execution environment, which is anything outside storage and code, are blocked during the validation prefix. Their results are not fixed at the time of admission, so a transaction could succeed off-chain and fail on-chain.

* **[OPCODES-010]** The following opcodes are blocked:
    * `GASPRICE` (`0x3A`)
    * `BLOCKHASH` (`0x40`)
    * `COINBASE` (`0x41`)
    * `TIMESTAMP` (`0x42`), except as [OPCODES-030](#opcode-rules-opcodes) allows
    * `NUMBER` (`0x43`)
    * `PREVRANDAO` / `DIFFICULTY` (`0x44`)
    * `GASLIMIT` (`0x45`)
    * `BASEFEE` (`0x48`)
    * `BLOBBASEFEE` (`0x4A`)
    * `SLOTNUM` (`0x4B`, [EIP-7843](./eip-7843.md))
    * `INVALID` (`0xFE`)
    * `SELFDESTRUCT` (`0xFF`)
    * `CREATE` (`0xF0`), `CREATE2` (`0xF5`) and `SETDELEGATE` (`0xF6`, [EIP-7819](./eip-7819.md)), except as [CREATION-010](#contract-creation-creation) and [CREATION-020](#contract-creation-creation) allow
* **[OPCODES-011]** `GAS` (`0x5A`) is allowed only when it is immediately followed by a `*CALL` instruction. This is the standard way to forward all remaining gas to a child call. The value is consumed from the stack at once and cannot be inspected.
* **[OPCODES-012]** Any unassigned opcode is blocked.
* **[OPCODES-020]** A revert on "out of gas" is forbidden, because it can leak the gas limit or the call-stack depth.
* **[OPCODES-030]** `TIMESTAMP` is allowed only while an `expiry_verify` frame executes the canonical runtime code at `EXPIRY_VERIFIER`.
* **[OPCODES-040]** `BALANCE` (`0x31`) and `SELFBALANCE` (`0x47`) are allowed only for a staked entity. Otherwise they are blocked.
* **[OPCODES-050]** `APPROVE`, `TXPARAM`, `FRAMEDATALOAD`, `FRAMEDATACOPY`, `FRAMEPARAM`, `SIGPARAM` and `SIGDATACOPY` are allowed. Their results depend only on the transaction and on the earlier validation frames, both of which are fixed at admission. `ORIGIN` is also allowed, since it returns a protocol constant in `DEFAULT` and `VERIFY` frames.

### Contract Creation (CREATION)

* **[CREATION-010]** `CREATE`, `CREATE2` and `SETDELEGATE` are allowed only inside the `deploy` frame, and only to install code or an EIP-7702 delegation indicator at `tx.sender`. `CREATE2` may be executed at most once, and it MUST deploy the code for `tx.sender`. It may be executed by the factory itself or by a utility contract that the factory calls.
* **[CREATION-020]** If the factory is a staked entity, it MAY additionally use `CREATE`, and it MAY use a utility contract that executes `CREATE`, to deploy `tx.sender`.

### Calls and Code Access (CALLING)

* **[CALLING-010]** Using an address that has no deployed code is forbidden. Exceptions: `tx.sender` may be used in the `deploy` frame, where the factory creates it, and `tx.sender`'s default-code behaviour is allowed. `CALLER` returns `ENTRY_POINT` and is allowed, but `ENTRY_POINT` itself holds no code, so it may not be called.
* **[CALLING-020]** Using an address whose code is an EIP-7702 delegation indicator is forbidden, except for `tx.sender`'s default-code behaviour.
* **[CALLING-030]** A `CALL` with non-zero `value` is forbidden. This can only occur in the `deploy` frame or in a `pre_verify` frame (see [Execution Model](#execution-model)).
* **[CALLING-040]** Precompiles that access nothing in the blockchain state or environment are allowed. These include the core precompiles `0x01` to `0x11` and the `P256VERIFY` precompile defined by [EIP-7951](./eip-7951.md). A node MUST NOT accept any other precompile until it has verified that the precompile has this property.

### Storage and State Access (STORAGE)

Storage access by `SLOAD`, `SSTORE`, `TLOAD` and `TSTORE` is restricted as follows. Writes and transient writes are possible only in the `deploy` frame and in `pre_verify` frames (see [Execution Model](#execution-model)).

* **[STORAGE-010]** Access to `tx.sender`'s own storage is always allowed.
* **[STORAGE-020]** Access to storage associated with `tx.sender` in an external contract that is not an entity of the transaction is allowed if either:
    * **[STORAGE-021]** the sender's account already exists, meaning the transaction has no `deploy` frame; or
    * **[STORAGE-022]** the transaction has a `deploy` frame and the factory is a staked entity.
* **[STORAGE-030]** If an entity, of any role, is a staked entity, it is additionally allowed:
    * **[STORAGE-031]** access to its own storage;
    * **[STORAGE-032]** read and write access to slots associated with the entity, in any contract that is not an entity of the transaction;
    * **[STORAGE-033]** read-only access to any storage in a contract that is not an entity of the transaction.
* **[STORAGE-040]** Transient storage ([EIP-1153](./eip-1153.md)) accessed with `TLOAD` and `TSTORE` is treated exactly like persistent storage accessed with `SLOAD` and `SSTORE`.
* **[STORAGE-110]** *(Local)* A transaction MUST NOT use as its factory or its sponsoring payer an address that is `tx.sender` of another pending transaction in the mempool. A factory or paymaster contract can therefore not also serve as an account.
* **[STORAGE-120]** *(Local)* A transaction MUST NOT use storage associated with its sender, or with a staked entity, in a contract that is `tx.sender` of another pending transaction in the mempool.

The relaxation over the public mempool is [STORAGE-020] and [STORAGE-030]. The public mempool allows storage reads only from `tx.sender` and forbids every other storage access.

### Stake (STAKING)

* **[STAKING-010]** An entity is staked if the Staking Registry reports for it a stake of at least `MIN_STAKE_VALUE` and an unstake delay of at least `MIN_UNSTAKE_DELAY`, and `withdrawTime` is zero, meaning no withdrawal has been initiated.
* **[STAKING-020]** A node reads stake information from the Staking Registry at `STAKING_REGISTRY_ADDRESS` against the state its validation runs against. If no registry is configured, every entity is unstaked.
* **[STAKING-030]** A default-code entity is never staked.

Stake is never slashed. It exists only for off-chain detection. The lock-up period raises the capital cost of creating new abusive entities.

### Payer Solvency (SOLVENCY)

* **[SOLVENCY-010]** For every payer, including the sender when it pays for itself, a node MUST track `reserved_pending_cost(payer)`, the sum of the maximum costs (`TXPARAM(0x06)`) of every pending transaction in its mempool that names this payer. A node MUST reject a transaction if `available_balance(payer)` is less than its maximum cost, where `available_balance(payer) = balance(payer) - reserved_pending_cost(payer)`.
* **[SOLVENCY-020]** For a canonical paymaster, `available_balance` additionally subtracts `pending_withdrawal_amount(paymaster)`, the amount of any delayed withdrawal currently pending in that paymaster.
* **[SOLVENCY-030]** On admission a node increases `reserved_pending_cost` by the transaction's maximum cost. It decreases it on eviction, replacement, inclusion and removal by reorg. When a replacement changes the payer, the node moves the reservation to the new payer atomically with the replacement.

This is the public mempool's reservation rule, applied to every payer, not only to canonical paymasters.

### Reputation (REPUTATION)

#### Definitions

1. **`seen`**: a per-entity counter of how many times this node received a unique valid transaction that references the entity. It counts transactions received over RPC and over the mempool network.
2. **`included`**: a per-entity counter of how many transactions that were previously counted in `seen` for that entity were included in a canonical block. A node determines this from the block's transactions and receipts.
3. **Refresh rate**: every hour, both counters are updated as `value = value * 23 // 24`. The effect is a reduction to about 1% after four days.
4. **`inclusionRate`**: the ratio of `included` to `seen`.

#### Calculation

Let `max_seen = seen // MIN_INCLUSION_RATE_DENOMINATOR`. The reputation of an entity is:

1. **BANNED**: `max_seen > included + BAN_SLACK`
2. **THROTTLED**: `max_seen > included + THROTTLING_SLACK`
3. **OK**: otherwise

A new entity starts as `OK`. Reputation is tracked per entity address, not per role. The refresh rate limits a malicious entity to about `BAN_SLACK * MIN_INCLUSION_RATE_DENOMINATOR / 24` invalid transactions per hour. This affects only the mempool network and never the chain.

#### General rules

The following rules apply to all staked entities and to unstaked sponsoring payers.

* **[REPUTATION-010]** A `BANNED` address is not allowed into the mempool. Every pending transaction that references it is removed.
* **[REPUTATION-020]** A `THROTTLED` address is limited to `THROTTLED_ENTITY_MEMPOOL_COUNT` entries in the mempool, to `THROTTLED_ENTITY_BLOCK_COUNT` transactions in a block the node builds, and to `THROTTLED_ENTITY_LIVE_BLOCKS` blocks of residency in the mempool.
* **[REPUTATION-030]** If a transaction passed the node's most recent revalidation but then fails when the node tries to include it in a block, every entity of that transaction that caused the failure has its `seen` set to `BAN_TXS_SEEN_PENALTY` and its `included` set to zero, so that it becomes `BANNED`.
* **[REPUTATION-040]** When a transaction is replaced by one with higher fees and the replacement removes an entity, such as a sponsoring payer, from the mempool, the removed entity's `seen` is decremented by 1.

#### Staked entities

* **[REPUTATION-110]** An `OK` staked entity faces no limit under the reputation rules. There is no cap on its pending transactions, or on its transactions in a block a node builds. The per-sender limit in [LIFECYCLE-010](#replacement-eviction-and-revalidation-lifecycle) still applies.

#### Unstaked entities

* **[REPUTATION-210]** An unstaked sender that is neither `THROTTLED` nor `BANNED` may have at most `SAME_SENDER_MEMPOOL_COUNT` pending transactions in the mempool.
* **[REPUTATION-220]** An unstaked sponsoring payer that is neither `THROTTLED` nor `BANNED` may have at most `opsAllowed` pending transactions in the mempool, where `opsAllowed = SAME_UNSTAKED_ENTITY_MEMPOOL_COUNT + inclusionRate * min(included, MAX_TXS_ALLOWED_UNSTAKED_ENTITY)`. For a new entity this is `SAME_UNSTAKED_ENTITY_MEMPOOL_COUNT`.

[REPUTATION-220] replaces the public mempool's `MAX_PENDING_TXS_USING_NON_CANONICAL_PAYMASTER` cap of one pending transaction per non-canonical paymaster. It lets an unstaked payer with a good record carry more.

#### Blame attribution

* **[REPUTATION-310]** If a transaction fails revalidation because of an earlier validation frame, that is, the factory or the sender, the sponsoring payer's `seen` is decremented by 1. A payer must not lose reputation because of another entity's failure.
* **[REPUTATION-320]** If a staked factory is used and the sender's validation frame fails, the failure is attributed to the factory, and the factory's reputation is updated accordingly.
* **[REPUTATION-330]** If a staked sender is used, its reputation is updated by failures of the other entities of the transaction, even if those entities are staked.

### Replacement, Eviction and Revalidation (LIFECYCLE)

* **[LIFECYCLE-010]** A pending transaction is identified by `(sender, nonce)`. Two transactions with the same identity are alternatives, at most one of which can ever be included. A node MUST keep at most `SAME_SENDER_MEMPOOL_COUNT` pending transactions per sender.
* **[LIFECYCLE-020]** A replacement MUST be valid under every rule in this document. A node SHOULD accept and propagate it only if it increases both `max_fee_per_gas` and `max_priority_fee_per_gas` by at least a configured minimum increment. 10% is the conventional default. A replacement MAY name a different payer.
* **[LIFECYCLE-030]** When a node's resource limits are reached, it SHOULD evict in this order: transactions that are already invalid against the current head, then transactions with the nearest expiry deadline, then transactions with the lowest effective priority fee. Evicted and replaced transactions MUST NOT be propagated again.
* **[LIFECYCLE-040]** When a new canonical block is accepted, a node MUST remove the transactions the block includes and update payer reservations. It MUST revalidate every pending transaction that depends on state the block changed. This includes at least:
    * transactions for the same sender;
    * transactions whose recorded storage dependencies changed;
    * transactions whose payer's balance or code changed;
    * transactions that reference a canonical paymaster whose balance, code or delayed-withdrawal state changed;
    * transactions that reference an entity whose stake status changed.

  A transaction that no longer satisfies the rules MUST be evicted.
* **[LIFECYCLE-050]** A node SHOULD record, for each admitted transaction, the set of state it depended on: the storage slots read, and the code, balance and nonce of every address whose value the validation used. It SHOULD use this set to select the transactions that [LIFECYCLE-040] requires it to revalidate, without re-executing the others.
* **[LIFECYCLE-060]** When revalidation causes a transaction to fail because of an entity's behaviour, the reputation rules in [Reputation](#reputation-reputation) apply to that entity.
* **[LIFECYCLE-070]** *Code stability.* The `EXTCODEHASH` of every address that a validation frame visited, every entity, and every library it referenced MUST NOT change between admission validation and revalidation. If it does, the transaction is invalid.

### Propagation (PROPAGATION)

The wire protocol is out of scope for this document. The following rules apply to any transport that carries transactions between nodes of the standard mempool.

* **[PROPAGATION-010]** A transaction is broadcast with two items: the transaction itself, and the block hash against which it was last validated.
* **[PROPAGATION-020]** A node that receives a transaction from a peer MUST validate it locally before it propagates it.
* **[PROPAGATION-030]** If a received transaction fails a static check, such as an invalid encoding, a value below a minimum, or an outdated block hash, the node drops it and keeps the connection.
* **[PROPAGATION-040]** A node silently drops a transaction whose `(sender, nonce)` was recently included in a block. This is almost certainly a network race. It causes no reputation change.
* **[PROPAGATION-050]** If a received transaction fails against the current block, the node retries validation against the block named in the transaction's message. If it succeeds, the node silently drops the transaction and keeps the connection. If it fails, the node marks the sending peer a **spammer**, disconnects from it and blocks it permanently.

### Alternative Mempools

The standard mempool is not the only possible rule set. Node operators may agree on alternative mempools, rule sets that a node opts into in addition to the standard mempool, and this document deliberately does not define or restrict them. Each alternative mempool is identified by its own topic, conventionally the IPFS hash of a document that describes its rules. A transaction that violates a standard rule MUST NOT be propagated in the standard mempool, but MAY be propagated in any alternative mempool whose rules it satisfies. Reputation counters (`seen` and `included`) SHOULD be kept separately for each mempool, so that an entity that is throttled in one mempool is unaffected in another. An alternative mempool MAY define its own peer standing rules.

### Acceptance Algorithm

A node applies the rules in this order:

1. Validate the signatures ([SIGNATURE-010]).
2. Determine the validation prefix and check its structure ([PREFIX-010] to [PREFIX-080], [PREFIX-110], [PREFIX-120], [BUDGET-010], [BUDGET-020]).
3. Resolve each entity's role, address and stake ([STAKING-010]) and check reputation ([REPUTATION-010], [REPUTATION-020], [REPUTATION-210], [REPUTATION-220]).
4. Simulate the prefix and trace it, applying [OPCODES], [CREATION], [CALLING] and [STORAGE] to every validation frame that is not protocol-defined. Stop at [PREFIX-090].
5. Check payer solvency and reserve the cost ([SOLVENCY-010] to [SOLVENCY-030]).
6. Check the per-sender limit ([LIFECYCLE-010]), and, if the transaction is a replacement, the replacement rule ([LIFECYCLE-020]).
7. If every check passes, record the dependency set ([LIFECYCLE-050]), admit the transaction and propagate it ([PROPAGATION-010]).

## Rationale

### Relationship to the public mempool

EIP-8141's public mempool is deliberately narrow. It permits reading only `tx.sender`'s storage, and it caps non-canonical paymasters at one pending transaction each. That is the correct default for a network with no way to attribute blame. It cannot host validation that legitimately depends on shared state: a shielded pool's Merkle roots, a registry of authorised signers, or a paymaster with a budget in its own storage. Stake and reputation give a node what the public mempool lacks: an economic cost for creating an abusive entity, and a mechanism that throttles an entity once it causes invalidations.

Because the standard mempool extends the public mempool rather than replacing it, the two stay consistent. A wallet author who targets the public mempool needs no knowledge of this document.

### Rationale for `pre_verify` frames

ERC-4337 validation functions may write storage, under the same associated-storage and stake rules that govern reads. A common use is a paymaster that pulls ERC-20 tokens from the sender during validation, so that it is reimbursed before it commits to pay. `VERIFY` frames are static, so the same guarantee needs a non-static frame that runs before the `pay` frame. `DEFAULT`-mode frames already provide that. The alternatives are weaker. A `SENDER` frame after `pay` runs only once the payer has committed, and a post-operation frame leaves the payer with the loss if the transfer fails.

The `pre_verify` subclass marks such a frame, binds it to one approving frame so that each write is attributed to an entity, and allows only one per approving frame. Attribution is what lets the storage and reputation rules apply to writes exactly as they apply to reads. One frame is enough, because its target can call any number of contracts.

### Revalidation instead of a second validation

ERC-7562 validates a `UserOperation` a second time immediately before it enters a bundle, and once more over the whole bundle. That protects the bundler's own self-paid transaction from going stale. A frame transaction is already signed and pays for itself, so there is no such transaction to protect. State still changes after admission, so a node revalidates on every new head and again before it includes a transaction in a block it builds. [REPUTATION-030] and [LIFECYCLE-040] carry the purposes of the second validation. Blame is assigned when revalidation finds that an entity's behaviour changed.

### Definition of the mass invalidation attack TODO move to definitions section in the beginning

A series of actions is a **mass invalidation attack** if a large number of transactions, having passed admission validation and propagated through the mempool network, later become invalid and ineligible for inclusion.

There are three ways to carry it out:

1. Submitting transactions that pass admission validation and fail revalidation.
2. Submitting transactions that are valid alone but become invalid when several of them are included together.
3. Front-running valid transactions with an economically viable state change that invalidates them.

To prevent these, validation code runs in a sandbox. It is isolated from other transactions, from external storage changes, and from environment information such as the block timestamp.

A transaction that fails admission validation and never enters the mempool is not an attack. Nodes are expected to apply ordinary measures against spam, such as throttling by API key, IP address, or peer score. An attack is also not considered economically viable if invalidating `N` transactions costs the attacker `N * X` for a sufficiently large `X`. The cheapest invalidating change is a storage write, at 5,000 gas. If a node can process 2,000 invalid transactions per block, such an attack costs 10,000,000 gas per block. The rules in this document add further costs on top.

## Backwards Compatibility

TODO elaborate how we maintain a backward compatibility of use-cases (token paymasters, privacy pools, staked paymasters with associated storage etc.) for projects that grew to rely on code shaped by 4337+7562.

This document introduces no consensus change and requires no change to EIP-8141. It does not modify ERC-4337 or ERC-7562. It replaces the frame transaction sections of any draft of ERC-7562 that included them. A node may implement this document alongside ERC-7562, since the two apply to different transaction types.

A node that implements only the public mempool of EIP-8141 remains compatible. Every transaction it propagates satisfies this document's structure, budget and trace rules, subject to the exceptions listed in [Relationship to Other Mempools](#relationship-to-other-mempools).

## Security Considerations

**Staking Registry.** The stake provisions depend on a registry contract outside the EIP-8141 protocol. Its correctness is not guaranteed by the protocol. A registry that reports stake incorrectly weakens [STORAGE-030], [OPCODES-040] and [CREATION-020].

**Staked entities can still misbehave.** A staked entity can cause a bounded amount of invalidation before its reputation drops. The bound is `BAN_SLACK * MIN_INCLUSION_RATE_DENOMINATOR / 24` invalid transactions per hour, plus whatever throttling then allows. It is a rate limit, not a guarantee.

**`pre_verify` frames run before approval.** A `pre_verify` frame is called by `ENTRY_POINT`, before any `APPROVE` has happened, so nobody has been authorised yet. A contract that treats "the caller is `ENTRY_POINT`" as authority can be made to write by a transaction whose sender is someone else. The target of a `pre_verify` frame SHOULD check that the transaction's sender, as reported by `TXPARAM`, is the party whose state it is about to change.

**A failed `DEFAULT` frame does not invalidate the transaction.** Only `VERIFY` failures do, so a `pre_verify` frame that reverts on-chain lets the transaction continue. [PREFIX-120] requires the approving frame to check for this. A node cannot check the requirement, so a payer that ignores it bears the loss.

**Approval covers all following `SENDER` frames.** `sender_approved` is a single transaction-scoped flag (EIP-8141 §`APPROVE`). Once it is set, every `SENDER` frame in the transaction executes as `tx.sender`, not only the frame the approving code inspected. A node cannot check this. Wallet code that approves execution SHOULD bind its approval to the whole frame list, for example by verifying a signature over the canonical signature hash, which commits to every frame. A signature over an explicit digest that does not commit to the frame list authorises an open-ended set of `SENDER` frames.

**`ARBITRARY` signatures.** The protocol does not validate them, so a transaction that carries one is only as trustworthy as the frame that inspects it ([SIGNATURE-020]).

**Canonical paymaster.** A canonical paymaster is exempt from the trace rules and admitted by code match. A flaw in the canonical implementation affects every node that relies on the exemption.

**Default-code payers.** A payer with no code is bounded only by [SOLVENCY-010]. A sponsor that moves its balance elsewhere between admission and inclusion invalidates every pending transaction it sponsors, up to the balance it appeared to hold. Reservation limits the exposure to the payer's balance at admission time and does not remove it.

**Revalidation load.** A new head can force many revalidations. [LIFECYCLE-050] lets a node select only the affected transactions. A node that ignores it is exposed to a load attack proportional to the size of its mempool.

**Untested at scale.** Neither ERC-7562's rules nor the frame transaction rules here have seen adversarial production traffic at meaningful scale. Most historical ERC-4337 traffic bypassed the public peer network through private relays.

## Appendix A: Staking Registry Contract TODO move to Specification

Frame transactions have no `EntryPoint` contract to hold a stake ledger, and `ENTRY_POINT` holds no state. Stake is therefore kept in a separate contract at `STAKING_REGISTRY_ADDRESS`. It implements this interface:

```solidity
interface IStakingRegistry {
    /// Lock `msg.value` as the caller's stake, with the given unstake delay.
    function addStake(uint32 unstakeDelaySec) external payable;

    /// Begin the withdrawal delay. From this point the caller is not staked.
    function unlockStake() external;

    /// Withdraw the stake after the delay has passed.
    function withdrawStake(address payable withdrawAddress) external;

    /// Return the stake information a node needs to apply STAKING-010.
    function getDepositInfo(address account)
        external
        view
        returns (uint256 stake, uint32 unstakeDelaySec, uint64 withdrawTime);
}
```

`withdrawTime` is zero while no withdrawal has been initiated. A node applies [STAKING-010] to the values `getDepositInfo` returns.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE.md).
