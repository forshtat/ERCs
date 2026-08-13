// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title  IClearSigningRegistry — On-Chain Registry for ERC-7730 Clear Signing Descriptors
/// @notice Defines the interface for an Ethereum registry that maps ERC-7730 binding context IDs
///         to attester-attested descriptors backed by an arbitrary off-chain attestation mechanism.
interface IClearSigningRegistry {

    /// @notice An identifier of the Attestation used to discover the full attestation data in the off-chain index.
    ///         Additionally serves as a key to the on-chain attestation revocations mapping.
    struct AttestationIdentifier {
        /// The attester-chosen identifier of the attestation.
        bytes32 attestationId;
        /// A format identifier calculated as keccak256("erc7730.attestation.<format>")
        bytes32 attestationFormatId;
    }

    /// @notice Descriptor data provided to the 'createAttestations' function for new descriptor registration.
    struct DescriptorInfo {
        /// The ERC-8176 "descriptor hash" identifier of this Descriptor.
        bytes32 descriptorHash;
        /// The MAJOR version of the ERC-7730 descriptor schema per its '$schema' key.
        uint256 descriptorSchemaMajor;
        /// Context IDs this descriptor will be discoverable for.
        bytes32[] contextKeyIds;
        /// Identifiers and formats of all attestations relating to this Descriptor.
        AttestationIdentifier[] attestationIds;
    }

    /// @notice One attestation ID being revoked, together with the context IDs to clear immediately.
    struct RevocationEntry {
        bytes32 attestationId;
        bytes32[] contextKeyIds;
    }

    /// @notice A fully resolved active Attestation structure for ResolvedDescriptor.
    struct ResolvedAttestation {
        /// The attester that issued this particular attestation.
        address attester;
        /// The attester-chosen identifier of the attestation.
        bytes32 attestationId;
        /// A format identifier calculated as keccak256("erc7730.attestation.<format>")
        bytes32 attestationFormatId;
        /// The timestamp at which the attester revoked this attestation ID, or 0 if never
        /// revoked. Also reflects the attester's 'kill' timestamp — see 'getAttesterKilledAt'
        /// — when the specific ID was never individually revoked but the attester is killed.
        uint64 revokedAt;
    }

    /// @notice A fully resolved active Descriptor with Attestations.
    struct ResolvedDescriptor {
        /// The descriptor hash of this Descriptor.
        bytes32 descriptorHash;
        /// The context ID the descriptor was found under.
        bytes32 contextKeyId;
        /// The schema MAJOR the attestation set was found under.
        uint256 descriptorSchemaMajor;
        /// The attestation set ID from the active record — the key into the attestation index file.
        bytes32 attestationSetId;
        /// The full resolved array of URIs provided for this Descriptor in the MirrorList.
        string[] descriptorMirrorListUris;
        /// The MirrorList URIs of the index file for retrieving this set's attestation blobs.
        string[] attestationMirrorListUris;
        /// The full resolved array of attestation objects issued for this Descriptor matching the specified filter.
        ResolvedAttestation[] attestations;
    }

    /// @notice Emitted when an attester's active attestation set for a context ID changes.
    /// @param attester                  The attester whose active attestation set changed.
    /// @param contextKeyId                 The context ID affected.
    /// @param attestationSetId          The newly active attestation set ID, or bytes32(0) when cleared.
    /// @param previousAttestationSetId  The previously active attestation set ID.
    /// @param descriptorHash            The newly attested descriptor hash, or bytes32(0) when cleared.
    /// @param descriptorSchemaMajor               The schema MAJOR of the affected active record.
    event AttestationUpdated(
        address indexed attester,
        bytes32 indexed contextKeyId,
        bytes32 indexed attestationSetId,
        bytes32         previousAttestationSetId,
        bytes32         descriptorHash,
        uint256         descriptorSchemaMajor
    );

    /// @notice Emitted whenever a revocation timestamp is recorded for an ID —
    ///         an attestation set ID or an individual attestation ID alike.
    /// @param attester       The attester the ID is revoked under.
    /// @param attestationId  The revoked ID.
    /// @param timestamp      The block timestamp at which the revocation was recorded.
    event AttestationRevoked(
        address indexed attester,
        bytes32 indexed attestationId,
        uint64          timestamp
    );

    /// @notice Emitted exactly once per attestation set when its write-once metadata is stored during registration.
    ///
    /// @param attester          The attester the attestation set is registered under.
    /// @param attestationSetId  The registered attestation set ID.
    /// @param descriptorHash    The attested descriptor hash.
    /// @param descriptorSchemaMajor       The declared schema MAJOR.
    /// @param attestationIds    The full contents of the attestation set.
    event AttestationRegistered(
        address indexed attester,
        bytes32 indexed attestationSetId,
        bytes32 indexed descriptorHash,
        uint256         descriptorSchemaMajor,
        AttestationIdentifier[] attestationIds
    );

    /// @notice Emitted the first time a MirrorList is stored on-chain, carrying its full URI contents.
    /// @param mirrorListId  The content hash of the published MirrorList.
    /// @param uris          The published URI list.
    event MirrorListPublished(bytes32 indexed mirrorListId, string[] uris);

    /// @notice Emitted when an attester invalidates their current EIP-712 nonce via 'invalidateNonce'.
    ///         Indicates cancelling any outstanding signature using the old nonce value.
    /// @param attester  The attester whose nonce was invalidated.
    /// @param newNonce  The next valid nonce after the invalidation.
    event NonceInvalidated(address indexed attester, uint256 newNonce);

    /// @notice Emitted when an attester's active MirrorList for a descriptor changes.
    /// @param attester                The attester updating their list.
    /// @param descriptorHash          The descriptor hash.
    /// @param descriptorMirrorListId  The new MirrorList ID.
    event DescriptorMirrorListUpdated(
        address indexed attester,
        bytes32 indexed descriptorHash,
        bytes32 indexed descriptorMirrorListId
    );

    /// @notice Emitted when an attester's active MirrorList for an attestation set changes.
    /// @param attester                 The attester updating their list.
    /// @param attestationSetId         The attestation set ID.
    /// @param attestationMirrorListId  The new MirrorList ID.
    event AttestationMirrorListUpdated(
        address indexed attester,
        bytes32 indexed attestationSetId,
        bytes32 indexed attestationMirrorListId
    );

    /// @notice Emitted when an attester's profile/config is set or updated via 'setAttesterProfile'.
    /// @param attester         The attester whose profile changed.
    /// @param profileURI       The new profile document URI.
    /// @param revocationOracle The attester's revocation oracle (write-once — unchanged after the first call).
    /// @param killSwitchKey    The attester's current kill-switch key.
    event AttesterProfileUpdated(
        address indexed attester,
        string          profileURI,
        address         revocationOracle,
        address         killSwitchKey
    );

    /// @notice Emitted exactly once, permanently, when an attester is killed via 'kill'.
    /// @param attester  The attester that was killed.
    /// @param killedBy  The address that authorized the kill — 'attester' itself or its 'killSwitchKey'.
    /// @param timestamp The block timestamp at which the kill was recorded.
    event AttesterKilled(address indexed attester, address indexed killedBy, uint64 timestamp);

    /// @notice Thrown when descriptors is empty.
    error EmptyDescriptors();

    /// @notice Thrown when an empty key array is passed to an update function.
    error EmptyKeys();

    /// @notice Thrown when bytes32(0) is passed where a descriptor hash is required.
    error ZeroDescriptorHash();

    /// @notice Thrown when bytes32(0) is passed where an attestation format ID is required.
    error ZeroAttestationFormat();

    /// @notice Thrown when two attestations of the same descriptor declare the same format ID.
    error DuplicateAttestationFormat(bytes32 attestationFormatId);

    /// @notice Thrown when a descriptor declares a zero schema MAJOR version.
    error ZeroDescriptorSchemaMajor();

    /// @notice Thrown when bytes32(0) is passed where an attestation ID is required.
    error ZeroAttestationId();

    /// @notice Thrown when a descriptor's contextKeyIds is empty.
    error EmptyContextKeyIds();

    /// @notice Thrown when a descriptor's attestationIds is empty.
    error EmptyAttestationIds();

    /// @notice Thrown when 'revokeAttestations' is called with an empty 'revocations' array.
    error EmptyRevocations();

    /// @notice Thrown when a registration includes an attestation ID that was already revoked.,
    ///         Attestation IDs are single-use and cannot be re-registered after revocation.
    error AttestationIdAlreadyUsed(bytes32 attestationId);

    /// @notice Thrown when 'updateDescriptorMirrorList' names a descriptor hash the
    ///         attester has never registered.
    error UnknownDescriptor(bytes32 descriptorHash);

    /// @notice Thrown when 'updateAttestationMirrorList' names an attestation set ID the
    ///         attester has never registered.
    error UnknownAttestationSet(bytes32 attestationSetId);

    /// @notice Thrown when an empty URI list is passed to publishMirrorLists.
    error EmptyMirrorList();

    /// @notice Thrown when a MirrorList id passed to 'createAttestations',
    ///         'updateDescriptorMirrorList', or 'updateAttestationMirrorList' was
    ///         never published via 'publishMirrorLists'.
    error UnknownMirrorList(bytes32 mirrorListId);

    /// @notice Thrown when the registration is submitted by an address other than
    ///         the attester and the provided EIP-712 registration signature does
    ///         not verify against the attester.
    error InvalidRegistrationSignature();

    /// @notice Thrown when a descriptor replaces an active attestation set but the
    ///         previously active set id has not already been revoked via a prior
    ///         'revokeAttestations' call — 'createAttestations' never revokes on its own.
    error MissingRevocation(bytes32 missingAttestationId);

    /// @notice Thrown when 'setAttesterProfile' is called with a 'revocationOracle' value
    ///         that differs from the one already on record. The field is write-once: fixed
    ///         permanently by the attester's first call, to prevent an ambiguous mid-stream
    ///         change in which past attestations were synced under one trust assumption and
    ///         later ones under another.
    error RevocationOracleImmutable();

    /// @notice Thrown when 'setAttesterProfile' is called with 'killSwitchKey == attester'.
    error KillSwitchKeyEqualsAttester();

    /// @notice Thrown when 'setAttesterProfile' is called with 'killSwitchKey == address(0)'.
    ///         Unlike 'revocationOracle', a kill-switch key is mandatory: opting out would
    ///         defeat the one purpose this field exists for.
    error ZeroKillSwitchKey();

    /// @notice Thrown when 'setAttesterProfile' changes 'killSwitchKey' but 'killSwitchSignature'
    ///         does not verify as a valid 'KillSwitchBinding' signature by the new key itself —
    ///         proof that its holder controls it and consents to the binding.
    error InvalidKillSwitchSignature();

    /// @notice Thrown when 'kill' is called with a 'signature' that verifies against neither
    ///         the attester nor its registered 'killSwitchKey'.
    error InvalidKillSignature();

    /// @notice Thrown when 'kill' is called for an attester that is already killed.
    error AttesterAlreadyKilled();

    /// @notice Thrown by 'createAttestations' when 'attester' has been killed via 'kill' —
    ///         permanently and unconditionally, regardless of signature validity.
    error AttesterIsKilled();

    /// @notice Register a batch of descriptors backed by attestations.
    ///
    ///         The attester produces the signed attestation artifacts locally and stores them off-chain.
    ///         All attestations of a descriptor form one attestation set whose members are active together.
    ///         Every set SHOULD contain a standard ERC-8176 EAS off-chain attestation.
    ///         The registry itself is attestation-agnostic — each attestation carries a vendor format ID.
    ///
    ///         The registry does not validate any attestation's signature or content.
    ///
    ///         The registry derives an attestation set ID per descriptor.
    ///         A set with a single attestation uses that attestation's own ID directly.
    ///         A larger set uses 'keccak256(abi.encode(descriptorHash, descriptorSchemaMajor, attestationIds))'.
    ///
    ///         This call never revokes anything itself: replacing an active
    ///         '(contextKeyId, descriptorSchemaMajor)' record requires a prior, separate
    ///         'revokeAttestations' call for the displaced set id, or the call reverts with
    ///         'MissingRevocation'. Callers that want both steps in one transaction MUST
    ///         batch them themselves (e.g. via a multicall or an EIP-5792 call bundle) —
    ///         the registry does not provide atomicity across its own functions.
    ///
    ///         Reverts with 'AttesterIsKilled' if 'attester' has been killed via 'kill' —
    ///         permanently and unconditionally, regardless of signature validity.
    ///
    /// @param attester       The address of the attester registering the descriptors.
    /// @param descriptors    The descriptors to register, each carrying its attestation set.
    ///                       Active attestation sets are stored per '(contextKeyId, descriptorSchemaMajor)' keys.
    ///                       Descriptors of different schema MAJOR values never displace each other.
    ///                       Each '(contextKeyId, descriptorSchemaMajor)' active record may be written at most once per batch.
    ///
    /// @param descriptorMirrorListId  The id of an already-published MirrorList — see
    ///                       'publishMirrorLists' — for the index file containing all
    ///                       specified descriptors. Reverts with 'UnknownMirrorList' if unpublished.
    ///
    /// @param attestationMirrorListId The id of an already-published MirrorList for the
    ///                       index file containing all specified attestations. Reverts
    ///                       with 'UnknownMirrorList' if unpublished.
    ///
    /// @param signature      EIP-712 signature by the attester authorizing this batch.
    ///                       Required when the registration transaction is relayed.
    ///
    function createAttestations(
        address           attester,
        DescriptorInfo[]  calldata descriptors,
        bytes32           descriptorMirrorListId,
        bytes32           attestationMirrorListId,
        bytes             calldata signature
    ) external;

    /// @notice Publish a batch of MirrorLists on-chain.
    /// @param uriLists  The URI lists to publish. No list may be empty.
    function publishMirrorLists(string[][] calldata uriLists) external;

    /// @notice Revokes every specified attestation ID for the specified 'attester' and clears specified context IDs.
    ///         Entries may name attestation set IDs or individual attestation IDs.
    ///
    /// @param attester     The attester whose attestations are being revoked.
    /// @param revocations  The attestation IDs to revoke, each with the context IDs to clear.
    /// @param signature    EIP-712 signature by the attester authorizing this batch.
    ///                     Required when the revocation transaction is relayed.
    function revokeAttestations(
        address           attester,
        RevocationEntry[] calldata revocations,
        bytes             calldata signature
    ) external;

    /// @notice The timestamp at which 'attester' revoked 'attestationId', or 0 if neither
    ///         individually revoked nor covered by an attester-wide 'kill'.
    ///
    ///         Falls back to 'getAttesterKilledAt(attester)' when the specific ID was never
    ///         individually revoked but the attester has since been killed.
    ///
    /// @param attester       The attester whose revocation is being checked for the specified attestation ID.
    /// @param attestationId  The queried attestation ID.
    /// @return timestamp  The revocation timestamp, or 0 if not revoked.
    function getRevocationTimestamp(address attester, bytes32 attestationId) external view returns (uint64 timestamp);

    /// @notice Permissionlessly pull revocation state from 'attester's registered
    ///         'revocationOracle' — see 'setAttesterProfile' — for a batch of attestation
    ///         sets, and record any it reports as revoked.
    ///
    ///         For each 'attestationSetId': silently skipped (no revert, no state change) if
    ///         'attester' has no 'revocationOracle' configured (i.e. it is 'address(0)'), or
    ///         if the set is unknown to 'attester' — matching 'revokeAttestations'' existing
    ///         precedent of skipping stale/unknown references, so one bad ID in a batch from
    ///         many attesters does not poison the whole call.
    ///
    ///         For each known set's member attestation IDs, queries the oracle via a
    ///         gas-capped, return-size-capped 'staticcall' to 'IRevocationOracle.isRevoked'.
    ///         A revert, out-of-gas, or malformed return from the oracle is treated as
    ///         'false' (fail-closed) — this call never reverts because of a misbehaving
    ///         oracle. A 'true' result feeds the exact same one-way revocation record
    ///         'revokeAttestations' itself writes: once revoked, always revoked, regardless
    ///         of what the oracle reports afterward.
    ///
    /// @param attester           The attester whose attestations are being synchronized.
    /// @param attestationSetIds  The attestation sets to check against the oracle.
    function synchronizeRevocations(address attester, bytes32[] calldata attestationSetIds) external;

    /// @notice Resolve all active attestation sets for the specified query with a filter.
    ///         The request fields are:
    ///             1. The list of attesters trusted by the wallet.
    ///             2. The list of potential context IDs matching the relevant signature request.
    ///             3. The list of schema MAJOR versions supported by the wallet.
    ///             4. The list of attestation format IDs the wallet can verify.
    ///
    /// The 'attesters', 'contextKeyIds' and 'descriptorSchemaMajors' parameters are lookup keys - an empty array yields no results.
    /// An empty 'attestationFormatIds' or 'allowedPrefixes' array applies no filter for that parameter.
    ///
    /// A resolved descriptor is returned even if every one of its attestations is filtered out.
    ///
    /// @param attesters        Queried attester addresses trusted by the wallet.
    /// @param contextKeyIds       Candidate context IDs to look up.
    /// @param descriptorSchemaMajors     The schema MAJOR versions supported by the wallet.
    /// @param attestationFormatIds        Attestation format IDs to include, or empty array for all formats.
    /// @param allowedPrefixes  Raw string prefixes filtering the returned URI lists.
    ///                         e.g. ["ipfs:", "https:"].
    ///                         A URI is returned only if it starts with at least one of the prefixes.
    /// @return resolved   One 'ResolvedDescriptor' entry per active '(attester, contextKeyId, descriptorSchemaMajor)' record.
    function resolveDescriptors(
        address[] calldata attesters,
        bytes32[] calldata contextKeyIds,
        uint256[] calldata descriptorSchemaMajors,
        bytes32[] calldata attestationFormatIds,
        string[]  calldata allowedPrefixes
    ) external view returns (ResolvedDescriptor[] memory resolved);

    /// @notice Return the URI list for a given MirrorList ID.
    ///
    /// @param mirrorListId     The MirrorList content hash.
    /// @param allowedPrefixes  Raw string prefixes filtering the returned URIs, or empty array for no filters.
    ///
    /// @return uris  The fully resolved URI list.
    function getMirrorListById(bytes32 mirrorListId, string[] calldata allowedPrefixes)
        external view returns (string[] memory uris);

    /// @notice The next EIP-712 nonce for all relayed calls by the given attester.
    /// @param attester  The queried attester address.
    /// @return nonce  The next unused nonce.
    function getNonce(address attester) external view returns (uint256 nonce);

    /// @notice Invalidates the caller's current EIP-712 nonce and cancel any outstanding signature using that nonce.
    function invalidateNonce() external;

    /// @notice Permanently retires 'attester': every past and future attestation from this
    ///         address is treated as revoked (see 'getRevocationTimestamp',
    ///         'resolveDescriptors'), and 'createAttestations' rejects it forever after.
    ///
    ///         This is a one-way tombstone with no un-kill path — by design. The scenario
    ///         this exists for is a leaked attester signing key: a kill that only revoked
    ///         existing records but still let the compromised key register new ones would
    ///         not stop the attack it exists to defend against.
    ///
    ///         Writes a single O(1) flag with no iteration over the attester's existing
    ///         records — 'kill' costs the same regardless of how many attestations the
    ///         attester has outstanding, because revocation status is derived at read time
    ///         from this flag rather than written per record.
    ///
    ///         Callable directly by 'msg.sender == attester' or 'msg.sender ==
    ///         getKillSwitchKey(attester)' (signature ignored), or relayed with a
    ///         'signature' verifying against either key. Reverts with 'AttesterAlreadyKilled'
    ///         if already killed, or 'InvalidKillSignature' if the signature verifies
    ///         against neither key.
    ///
    /// @param attester   The attester being killed.
    /// @param signature  EIP-712 signature by the attester or its kill-switch key,
    ///                   authorizing this call. Required when relayed.
    function kill(address attester, bytes calldata signature) external;

    /// @notice The timestamp at which 'attester' was killed via 'kill', or 0 if never killed.
    /// @param attester  The queried attester address.
    /// @return timestamp  The kill timestamp, or 0 if not killed.
    function getAttesterKilledAt(address attester) external view returns (uint64 timestamp);

    /// @notice Update the MirrorList for existing descriptors without re-issuing attestations.
    /// @param attester The attester whose MirrorList pointers are being updated.
    /// @param descriptorHashes The hashes of the descriptors to update. Every hash MUST have
    ///                      been registered by the attester before, reverting with
    ///                      'UnknownDescriptor' otherwise.
    /// @param descriptorMirrorListId The id of an already-published MirrorList to rotate
    ///                      to — see 'publishMirrorLists'. Reverts with 'UnknownMirrorList' if unpublished.
    /// @param signature EIP-712 signature authorizing this update.
    function updateDescriptorMirrorList(
        address attester,
        bytes32[] calldata descriptorHashes,
        bytes32 descriptorMirrorListId,
        bytes calldata signature
    ) external;

    /// @notice Update the MirrorList for existing attestation sets without re-registration.
    /// @param attester The attester whose MirrorList pointers are being updated.
    /// @param attestationSetIds The IDs of the attestation sets to update. Every ID MUST have
    ///                      been registered by the attester before, reverting with
    ///                      'UnknownAttestationSet' otherwise.
    /// @param attestationMirrorListId The id of an already-published MirrorList to rotate
    ///                      to — see 'publishMirrorLists'. Reverts with 'UnknownMirrorList' if unpublished.
    /// @param signature EIP-712 signature authorizing this update (ignored if msg.sender == attester).
    function updateAttestationMirrorList(
        address attester,
        bytes32[] calldata attestationSetIds,
        bytes32 attestationMirrorListId,
        bytes calldata signature
    ) external;

    /// @notice Set or update an attester's profile document URI and lifecycle configuration.
    ///         Also serves as attester registration: an attester's first call fixes its
    ///         'revocationOracle' permanently and establishes its initial 'killSwitchKey'.
    ///
    ///         The profile URI is display-only metadata and MUST NOT be used as trust input.
    ///         Wallets select and trust attesters by address ONLY.
    ///         Consumers SHOULD render profile data only for attesters they already trust.
    ///
    ///         'revocationOracle' is mandatory on every call — 'address(0)' is a legitimate,
    ///         explicit value meaning "no external sync; native revocation only" — and is
    ///         write-once: any call after the first MUST repeat the value already on record,
    ///         or the call reverts with 'RevocationOracleImmutable'. See 'synchronizeRevocations'.
    ///
    ///         'killSwitchKey' is mandatory and MUST be non-zero and different from
    ///         'attester' (reverting with 'ZeroKillSwitchKey' / 'KillSwitchKeyEqualsAttester'
    ///         otherwise), but — unlike 'revocationOracle' — is rotatable: an attester may
    ///         change it in a later call. Whenever the call changes 'killSwitchKey' from its
    ///         currently stored value (including the first call, changing it from unset),
    ///         'killSwitchSignature' MUST verify as a 'KillSwitchBinding' signature by the
    ///         *new* key itself — proof that its holder controls it and consents to being
    ///         nominated — or the call reverts with 'InvalidKillSwitchSignature'. A call that
    ///         leaves 'killSwitchKey' unchanged ignores 'killSwitchSignature'. The key's only
    ///         capability anywhere in this interface is authorizing 'kill' — it cannot set a
    ///         profile, create or revoke attestations, or change the revocation oracle.
    ///
    /// @param attester            The attester whose profile/config is being set.
    /// @param profileURI          The new profile document URI.
    /// @param revocationOracle    The attester's revocation oracle — write-once, see above.
    /// @param killSwitchKey       The attester's kill-switch key — rotatable, see above.
    /// @param signature           EIP-712 signature by the attester authorizing this update.
    ///                            Required when the call is relayed.
    /// @param killSwitchSignature EIP-712 signature by 'killSwitchKey' binding it to
    ///                            'attester' — required only when 'killSwitchKey' changes.
    function setAttesterProfile(
        address         attester,
        string calldata profileURI,
        address         revocationOracle,
        address         killSwitchKey,
        bytes  calldata signature,
        bytes  calldata killSwitchSignature
    ) external;

    /// @notice The attester's current profile document URI, or an empty string if unset.
    /// @param attester  The queried attester address.
    /// @return profileURI  The profile document URI.
    function getAttesterProfileURI(address attester) external view returns (string memory profileURI);

    /// @notice The attester's registered revocation oracle, or 'address(0)' if it has opted
    ///         out of external sync (or never registered).
    /// @param attester  The queried attester address.
    /// @return revocationOracle  The oracle address, or 'address(0)'.
    function getRevocationOracle(address attester) external view returns (address revocationOracle);

    /// @notice The attester's current kill-switch key, or 'address(0)' if never registered.
    /// @param attester  The queried attester address.
    /// @return killSwitchKey  The kill-switch key address, or 'address(0)'.
    function getKillSwitchKey(address attester) external view returns (address killSwitchKey);
}
