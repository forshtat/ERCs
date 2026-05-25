Hi everyone,

First of all, I would like thank you for ERC-7730 - clear signing is easily one of the most important features for the wallets and it is long overdue for wide adoption.

I would also be happy to try contributing to this effort in any way I can.
I am getting into this ERC just now, coming into clear signing from the point of view of Account Abstraction (ERC-4337/EIP-8141) and Transaction Assertion (EIP-7906) features,
and looking for ways to expand and improve the ERC-7730 before it is finalized.
I tried to catch up with the last couple of years of discussions around this ERC where possible, but this is not an easy thing to do so I appologize if I end up retreading some old debates.

## 1. Native Account Abstraction support (ERC-4337, EIP-8141 and also EIP-7702)

In its current state ERC-7730 has some support for these features, however it seems somewhat limited.

As we now have wallets that are purely AA-based, and entire EVM-chains start going full AA, with Ethereum mainnet likely to follow very soon, I believe it is critical for ERC-7730 to support as many specifics of AA transactions as possible.

AA interactions are a little different from regular transactions and it would be unfortunate if we had to replace ERC-7730 with a different, AA-aware format in the near future.

Some specifics of AA interactions are:

### Atomic batching

AA operations may define relationships between executed steps ("execute A and B, but if any of these reverts, execute C or D").
One of the mechanisms to do so is defined in EIP-7867, an extension to EIP-5792, although there are many other competing approaches.

It would be difficult to express such a relationship using the current ERC-7730 as it only sees A, B, C and D as `calldata` bytes arrays, not as execution steps with copmplicated dependencies in their own right.

I expect atomic multi-step actions to become much more ubiquitous on Ethereum relatively soon, and the distinction between "approve(MAX_UINT256); swap(100); approve(0);" executed atomically and non-atomically is extremely significant -one is guaranteed to spend no more than 100 tokens, the other leaves an infinite dangling approval!

I understand that inter-call relationships are not properties of any individual function call, and how addressing this issue is stretching the scope of ERC-7730.
However, as ERC-7730 is the standardized channel for hardware wallets, so if we do not define at least some way of expressing these relationships, it will be hard to define them later.
My suggestion would be to define a thin, optional batch-level metadata in ERC-7730 to expose the relationship between `calldata` elements (atomic, sequential, etc.) so that this information is at least available if needed.

### Execution Composability

There is an interesting new proposal, ERC-8211 that addresses the issue of batched transactions that need some dynamic on-chain data as part of their inputs.
For example, a batch of "swap(1000 USDC -> ETH); stake(0.5 ETH)" may succeed or revert based on the actual ETH price in the 'swap'.

It seems like supporting these kinds of relationships will require the `"formats.fields"` array to be able to expose **outcome variables** of the execution step,
to be referenced in the following steps as inputs.

It would be very interesting to see if these two ERCs can be made to work together.

### Account Modularity

As mentioned already, some smart contract accounts may be modular (ERC-6900, ERC-7579 etc.), which is somewhat similar to a proxy contract with multiple implementations,
and this might make it non-trivial to determine the "context" for the actual execution being used.

The standards are pretty different, but it seems like we would need to extend the "context" matching to go deeper into the ERC-4337 UserOperation structure to discover all the necessary data in general.

### Delegate Calls

It may be not obvious if the call is made **to** a contract or if it is a call **delegated** to a contract without adding some native indication for delegate calls specifically.
Executing a delegatecall in the context of a smart contract account is one of the most dangerous things you can ever do in Ethereum.

### EIP-7702 Authorizations (see @wenzhenxiang)

As mentioned, seems like another case for extended "context" feature set.

## 2. Explicit extensibility mechanism

While ERC-7730 itself is clearly designed to be an extensible format, the text of the standard itself does not define a mechanism for such extensibility.

I suggest adopting an approach from ERC-5792 "capabilities" feature, by explicitly defining a way for writing extension ERCs, specifying what they can and cannot change in the core proposal.
There should also be a way for the wallet to request for the most suitable JSON specification from the registry.

Specifically, I believe `"context"`, `bytes` formatting (`raw`/`calldata`), encryption formats, internationalization of display strings, and container value sets (e.g. `@.from`, `@.value` and their semantics for novel transaction types) should be explicitly marked as extensible.

## 3. Transaction Outcome Simulation and Transaction Assertions

Currently, ERC-7730 treats the transaction simulation feature as being "downstream" of clear signing.

I believe the results of transaction simulation deserve to be displayed on the hardware wallet display as well, under a trust model similar to the one already used for clear signing specifications.

As ERC-7730 already solves the representational challenges of displaying structured transaction data, it would be natural to add an optional "simulation outcome" metadata format.

This becomes especially relevant in the context of Transaction Assertions (with or without EIP-7906) - a mechanism by which the smart contract account runs a post-transaction script verifying the actual changes match the original intention.
It is crucial that we can display these assertions inside the secure wallet interface.

## 4. Attestations

ERC-8176 proposes a good foundation for this, and I personally like the idea of natively defining a format for ERC-7730 specifications' attestation as part of the protocol.

## 5. Specifications Registry & Revocation process

I assume this should be a separate ERC, but it seems like a huge missed opportunity if we don't end up with some kind of an on-chain open public permissionless decentralized censorship-resistant open-source etc. registry for ERC-7730 specifications, and instead end up relying on Microsoft's github.com repository controlled by the Ethereum Foundation.

Practically, updating a git repo is also a relatively slow process.
If a well-known public contract ends up hacked, it may take a long time to revoke its specifications and remove it from the GitHub registry.
This can be made way faster and permissionlessly with on-chain registry with attestations.

Revocation is also something I believe should be explicitly defined in ERC-7730 - what the "revoked" specification looks like?

Please let me know if there is already an ongoing effort to define and implement something like that. I would love to learn more about it.

## 6. Proxy detection

It seems like there is no universal mechanism to confidently detect a contract as a proxy with a single known implementation.
However, in your opinion, would it be useful to define a universal "eth_getProxyImplementation" heuristic API with a formally defined behavior?

This seems like a very significant part of a clear signing process, and it sounds a little bit underspecified.

## 7. Field-level descriptions

The current field format specification supports a `label` as a short name like "Amount", but has no place for a longer plain-language explanation of what a field means in context.

It may not always be actually clear what the meaning of a field is.

For example:

```
Amount: 10 USDC
ⓘ This is the maximum amount of tokens you are willing to sell. The actual amount may be less.
```

An optional `description` key on field format specifications would cover this naturally.
Wallets with enough screen space to show a "more info" pop-up could display it, and resource-constrained hardware wallets would simply ignore it.

---

Please let me know if any of these are already being addressed in other ERCs or were explicitly rejected.
I would love to hear your feedback and to start prototyping approved ideas as well.

Thanks!
