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

My suggestion is to expose relationships between `calldata` elements in the ERC-7730 description of a batch, and work on making "interpolatedIntent" field compatible with grammatically correct expressions of such relationships. 

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

Specifically, I believe `"context"`, `bytes` formatting (`raw`/`calldata`), encryption formats etc. should be explicitly marked as extensible.

## 3. Transaction Outcome Simulation and Transaction Assertions

Currently ERC-7730 treates transaction simulation feature as being "downstream" of clear signing.

This may be a controversial take, but I believe the results of the transaction simulation deserve to be displayed on the hardware wallet display as well:
The data shown in the simulation is not more or less trusted compared to the "clear signing" specification - it is returned by a wallet backend and is probably signed by this backend's key to prevent tampering.
If the security assumptions is a "compromized laptop interacting with non-compromized hardware wallet", it is much better to display the outcome of the transaction simulation on the hardened device.

And as ERC-7730 already solves a lot of the issues related to representing a transaction signature request to the user, it may be better to just add support for "simulation" outcome metadata in the ERC-7730.
This may include things like storage layout, contract's roles, actual values etc.

This becomes especially relevant in the context of Transaction Assertions, a mechanism by which the smart contract account runs a post-transaction script verifying the actual changes match the original intention.

## 4. Attestations

I did not look into ERC-8176 yet, however I agree with the idea of natively defining a format for ERC-7730 specifications' attestation as part of the protocol.

Otherwise we seem to be creating a very locked-down ecosystem where each wallet will need to solve this issue on its own backend server, and some will surely fail to solve it securely, and users will lose funds.

Maintaining public standardized attestations along the public registry will lower the barrier to safe adoption of ERC-7730 for all wallets by a lot.

## 5. Specifications Registry & Revocation process

I assume this can be a separate ERC or not, but it seems like a missed opportunity if we don't end up with some kind of an on-chain open public permissionless decentralized censorship-resistant open-source etc. registry for ERC-7730 specifications, and instead end up relying on Microsoft's github.com repository controlled by the Ethereum Foundation.

Practically, updating a git repo is also a relatively slow process. If a well known public contract ends up hacked, it may take a long time to revoke its specifications and remove it from the github registry.
This can be made instantaneous on-chain.

Please let me know if there is already an ongoing effort to implement something like that, I would love to learn more.


