// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "./IClearSigningRegistry.sol";
import "./IRevocationOracle.sol";
import "./ClearSigningRegistryConstants.sol";
import "./UriFilterLib.sol";
import "./RegistrationHashLib.sol";
import "./openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "./openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title  ClearSigningRegistry — On-Chain Registry for ERC-7730 Clear Signing Descriptors
/// @notice Reference implementation of IClearSigningRegistry.
contract ClearSigningRegistry is IClearSigningRegistry, EIP712 {
    using UriFilterLib for string[];

    constructor() EIP712("ClearSigningRegistry", "1") {}

    // The attestation set ID currently active for the given attester, context ID and
    // schema MAJOR. Records of different schema MAJORs never displace each other.
    // The attested descriptor hash is stored in '_attestationSetDetails'.
    mapping(address attester => mapping(bytes32 contextKeyId => mapping(uint256 descriptorSchemaMajor => bytes32)))
        private _activeAttestationSetIds;

    // Write-once metadata of an attestation set.
    struct AttestationSetDetails {
        bytes32 descriptorHash;
        uint256 descriptorSchemaMajor;             // the declared schema MAJOR; opaque to the registry
    }
    mapping(address attester => mapping(bytes32 attestationSetId => AttestationSetDetails))
        private _attestationSetDetails;

    // The members of an attestation set, stored on-chain so 'resolveDescriptors' can
    // return and format-filter them. Written once, together with the set details.
    mapping(address attester => mapping(bytes32 attestationSetId => AttestationIdentifier[]))
        private _attestationSetContents;

    // The timestamp at which 'attester' revoked the given ID — an attestation set ID or
    // an individual attestation ID; both live in this one namespace — or 0 if never
    // revoked. Written by a 'revokeAttestations' batch (submitted directly or relayed
    // with a signature), or by this registry itself when a registration batch displaces
    // an attestation set on the attester's behalf — in the relayed cases only after
    // verifying that batch's own authorization chain.
    mapping(address attester => mapping(bytes32 attestationId => uint64)) private _revokedAt;

    // Global store of MirrorLists, written once per unique URI set.
    mapping(bytes32 mirrorListId => string[]) private _mirrorLists;

    // Per-attester pointer to the MirrorList this attester designates for the given descriptor hash.
    mapping(address attester => mapping(bytes32 descriptorHash => bytes32)) private _descriptorMirrorListIds;

    // Per-attester pointer to the MirrorList this attester designates for the given attestation set.
    mapping(address attester => mapping(bytes32 attestationSetId => bytes32)) private _attestationMirrorListIds;

    // EIP-712 nonce shared by all relayed calls: registration batches, revocation
    // batches, MirrorList updates and profile updates. Consumable without effect
    // via 'invalidateNonce'.
    mapping(address attester => uint256) private _nonces;

    // Self-declared profile document URI per attester ("business card").
    // Display-only metadata, never trust input; empty when unset.
    mapping(address attester => string) private _attesterProfileURIs;

    // The attester's registered external revocation source for 'synchronizeRevocations',
    // or 'address(0)' if opted out. Write-once — '_revocationOracleConfigured' tracks
    // whether it has ever been set, since 'address(0)' is itself a legitimate stored value
    // and cannot serve as its own "unset" sentinel.
    mapping(address attester => address) private _revocationOracles;
    mapping(address attester => bool)    private _revocationOracleConfigured;

    // The attester's current kill-switch key — rotatable, unlike the revocation oracle.
    // Its only capability anywhere in this contract is authorizing 'kill'.
    mapping(address attester => address) private _killSwitchKeys;

    // The timestamp at which an attester was permanently killed via 'kill', or 0 if never
    // killed. Consulted (never iterated) wherever revocation status or registration
    // eligibility is determined, so killing costs one write regardless of how many active
    // records the attester holds.
    mapping(address attester => uint64) private _attesterKilled;

    /// Gas stipend for the 'staticcall' to an attester's revocation oracle in
    /// 'synchronizeRevocations'. Bounds both the oracle's execution and how much return
    /// data it can plausibly produce; the call site additionally copies at most 32 bytes of
    /// that return data regardless of what the oracle claims to return.
    uint256 private constant REVOCATION_ORACLE_GAS_STIPEND = 30_000;

    /// @inheritdoc IClearSigningRegistry
    function createAttestations(
        address           attester,
        DescriptorInfo[]  calldata descriptors,
        bytes32           descriptorMirrorListId,
        bytes32           attestationMirrorListId,
        bytes             calldata signature
    ) external {
        if (_attesterKilled[attester] != 0) {
            revert AttesterIsKilled();
        }
        if (descriptors.length == 0) {
            revert EmptyDescriptors();
        }

        // Both MirrorLists must already be published — publishMirrorLists is the only
        // way to add one, so this call can never create new MirrorList content itself.
        _requireMirrorListPublished(descriptorMirrorListId);
        _requireMirrorListPublished(attestationMirrorListId);

        // Authorize the batch before any attester-scoped state is touched.
        _authorizeRegistration(attester, descriptors, descriptorMirrorListId, attestationMirrorListId, signature);

        // This call never revokes anything itself: a descriptor that displaces an
        // active record requires that record's set id to already be revoked — via an
        // earlier, separate 'revokeAttestations' call — or '_updateActiveAttestation'
        // reverts with 'MissingRevocation'. Callers that want both steps atomically
        // MUST batch them themselves (e.g. multicall or an EIP-5792 call bundle).
        _processAllDescriptors(attester, descriptors, descriptorMirrorListId, attestationMirrorListId);
    }

    /// @dev Reverts with 'UnknownMirrorList' unless 'mirrorListId' was already published.
    function _requireMirrorListPublished(bytes32 mirrorListId) private view {
        if (_mirrorLists[mirrorListId].length == 0) {
            revert UnknownMirrorList(mirrorListId);
        }
    }

    /// @dev Consumes a nonce and verifies the attester's EIP-712 batch signature for
    ///      relayed registrations; a no-op when the attester submits the batch directly.
    function _authorizeRegistration(
        address           attester,
        DescriptorInfo[]  calldata descriptors,
        bytes32           descriptorMirrorListId,
        bytes32           attestationMirrorListId,
        bytes             calldata signature
    ) private {
        if (msg.sender == attester) {
            return;
        }
        uint256 nonce = _nonces[attester];
        _nonces[attester] = nonce + 1;
        _verifyRegistrationSignature(
            attester, descriptors, descriptorMirrorListId, attestationMirrorListId, nonce, signature
        );
    }

    /// @dev Validates and processes every descriptor in a batch.
    function _processAllDescriptors(
        address                   attester,
        DescriptorInfo[] calldata descriptors,
        bytes32                   descriptorMirrorListId,
        bytes32                   attestationMirrorListId
    ) private {
        uint256 descriptorCount = descriptors.length;
        for (uint256 descriptorIndex = 0; descriptorIndex < descriptorCount; descriptorIndex++) {
            _processDescriptor(
                attester, descriptors[descriptorIndex], descriptorMirrorListId, attestationMirrorListId
            );
        }
    }

    /// @dev Updates the active record for each (contextKeyId, descriptorSchemaMajor) key of a
    ///      descriptor. Records of other schema MAJORs are untouched.
    function _updateActiveAttestation(
        address                 attester,
        DescriptorInfo calldata descriptor,
        bytes32                 attestationSetId
    ) private {
        bytes32[] calldata contextKeyIds  = descriptor.contextKeyIds;
        uint256   descriptorSchemaMajor          = descriptor.descriptorSchemaMajor;
        for (uint256 contextKeyIndex = 0; contextKeyIndex < contextKeyIds.length; contextKeyIndex++) {
            bytes32 contextKeyId                = contextKeyIds[contextKeyIndex];
            bytes32 previousAttestationSetId = _activeAttestationSetIds[attester][contextKeyId][descriptorSchemaMajor];

            // A record already pointing at this set — a re-activation batch listing existing
            // context IDs alongside new ones — is left untouched rather than displaced.
            if (previousAttestationSetId == attestationSetId) {
                continue;
            }

            // A displaced active attestation set must already be recorded as revoked — by
            // an earlier, separate 'revokeAttestations' call; this function never revokes
            // anything itself. Checking at the moment each pointer is written also covers
            // displacement by a duplicate (contextKeyId, descriptorSchemaMajor) key within the same batch.
            if (previousAttestationSetId != bytes32(0) && _revokedAt[attester][previousAttestationSetId] == 0) {
                revert MissingRevocation(previousAttestationSetId);
            }

            _activeAttestationSetIds[attester][contextKeyId][descriptorSchemaMajor] = attestationSetId;
            emit AttestationUpdated(
                attester, contextKeyId, attestationSetId, previousAttestationSetId,
                descriptor.descriptorHash, descriptorSchemaMajor
            );
        }
    }

    /// @inheritdoc IClearSigningRegistry
    function publishMirrorLists(string[][] calldata uriLists) external {
        uint256 listCount = uriLists.length;
        for (uint256 listIndex = 0; listIndex < listCount; listIndex++) {
            _publishMirrorList(uriLists[listIndex]);
        }
    }

    /// @dev Stores 'uris' keyed by its content hash. Idempotent: a list with identical
    ///      content is stored exactly once and emits no event on repeated publication.
    function _publishMirrorList(string[] calldata uris) private returns (bytes32 mirrorListId) {
        if (uris.length == 0) {
            revert EmptyMirrorList();
        }
        mirrorListId = keccak256(abi.encode(uris));
        string[] storage storedUris = _mirrorLists[mirrorListId];
        if (storedUris.length == 0) {
            // Element-by-element copy: a whole-array 'storedUris = uris' assignment of
            // nested calldata arrays is only supported by the IR pipeline ('via-ir').
            for (uint256 uriIndex = 0; uriIndex < uris.length; uriIndex++) {
                storedUris.push(uris[uriIndex]);
            }
            emit MirrorListPublished(mirrorListId, uris);
        }
    }

    /// @inheritdoc IClearSigningRegistry
    function revokeAttestations(
        address           attester,
        RevocationEntry[] calldata revocations,
        bytes             calldata signature
    ) external {
        if (revocations.length == 0) {
            revert EmptyRevocations();
        }
        if (msg.sender != attester) {
            uint256 nonce = _nonces[attester];
            _nonces[attester] = nonce + 1;
            _verifyRevocationSignature(attester, revocations, nonce, signature);
        }
        _processRevocations(attester, revocations);
    }

    /// @inheritdoc IClearSigningRegistry
    function invalidateNonce() external {
        uint256 newNonce = _nonces[msg.sender] + 1;
        _nonces[msg.sender] = newNonce;
        emit NonceInvalidated(msg.sender, newNonce);
    }

    /// @inheritdoc IClearSigningRegistry
    function setAttesterProfile(
        address         attester,
        string calldata profileURI,
        address         revocationOracle,
        address         killSwitchKey,
        bytes  calldata signature,
        bytes  calldata killSwitchSignature
    ) external {
        if (killSwitchKey == attester) {
            revert KillSwitchKeyEqualsAttester();
        }
        if (killSwitchKey == address(0)) {
            revert ZeroKillSwitchKey();
        }

        bool oracleConfigured = _revocationOracleConfigured[attester];
        if (oracleConfigured && _revocationOracles[attester] != revocationOracle) {
            revert RevocationOracleImmutable();
        }

        // A changing key (including the very first registration, changing it from unset)
        // always requires a fresh binding signature from the new key itself — regardless of
        // who submits this call — proving its holder controls it and consents to being
        // nominated. An unchanged key needs no re-proof.
        bool killSwitchChanging = _killSwitchKeys[attester] != killSwitchKey;
        _authorizeProfileUpdate(
            attester, profileURI, revocationOracle, killSwitchKey, killSwitchChanging, signature, killSwitchSignature
        );

        if (!oracleConfigured) {
            _revocationOracles[attester] = revocationOracle;
            _revocationOracleConfigured[attester] = true;
        }
        _killSwitchKeys[attester] = killSwitchKey;

        bool profileURIChanged =
            keccak256(bytes(_attesterProfileURIs[attester])) != keccak256(bytes(profileURI));
        if (profileURIChanged) {
            _attesterProfileURIs[attester] = profileURI;
        }

        if (profileURIChanged || killSwitchChanging || !oracleConfigured) {
            emit AttesterProfileUpdated(attester, profileURI, revocationOracle, killSwitchKey);
        }
    }

    /// @dev Consumes a nonce (once, if either signature was verified) and verifies the
    ///      relayed attester signature and/or the kill-switch binding signature for
    ///      'setAttesterProfile', as applicable — split out from the caller to keep its own
    ///      stack frame small.
    function _authorizeProfileUpdate(
        address         attester,
        string calldata profileURI,
        address         revocationOracle,
        address         killSwitchKey,
        bool            killSwitchChanging,
        bytes  calldata signature,
        bytes  calldata killSwitchSignature
    ) private {
        bool relayed = msg.sender != attester;
        if (!relayed && !killSwitchChanging) {
            return;
        }
        uint256 nonce = _nonces[attester];
        if (relayed) {
            _verifyProfileUpdateSignature(attester, profileURI, revocationOracle, killSwitchKey, nonce, signature);
        }
        if (killSwitchChanging) {
            _verifyKillSwitchBinding(attester, killSwitchKey, nonce, killSwitchSignature);
        }
        _nonces[attester] = nonce + 1;
    }

    /// @inheritdoc IClearSigningRegistry
    function getAttesterProfileURI(address attester) external view returns (string memory) {
        return _attesterProfileURIs[attester];
    }

    /// @inheritdoc IClearSigningRegistry
    function getRevocationOracle(address attester) external view returns (address) {
        return _revocationOracles[attester];
    }

    /// @inheritdoc IClearSigningRegistry
    function getKillSwitchKey(address attester) external view returns (address) {
        return _killSwitchKeys[attester];
    }

    /// @inheritdoc IClearSigningRegistry
    function getAttesterKilledAt(address attester) external view returns (uint64) {
        return _attesterKilled[attester];
    }

    /// @inheritdoc IClearSigningRegistry
    function kill(address attester, bytes calldata signature) external {
        if (_attesterKilled[attester] != 0) {
            revert AttesterAlreadyKilled();
        }

        address killSwitchKey = _killSwitchKeys[attester];
        if (msg.sender != attester && msg.sender != killSwitchKey) {
            uint256 nonce = _nonces[attester];
            _nonces[attester] = nonce + 1;
            bytes32 structHash = keccak256(
                abi.encode(ClearSigningRegistryConstants.ATTESTER_KILL_TYPEHASH, attester, nonce)
            );
            bytes32 digest = _hashTypedDataV4(structHash);
            bool validAttesterSignature = SignatureChecker.isValidSignatureNow(attester, digest, signature);
            bool validKillSwitchSignature =
                killSwitchKey != address(0) && SignatureChecker.isValidSignatureNow(killSwitchKey, digest, signature);
            if (!validAttesterSignature && !validKillSwitchSignature) {
                revert InvalidKillSignature();
            }
        }

        // Single O(1) write — no iteration over the attester's existing records. Every
        // read path (getRevocationTimestamp, resolveDescriptors) and createAttestations
        // consults this flag directly instead, so killing costs the same regardless of how
        // many attestations the attester has outstanding.
        uint64 timestamp = uint64(block.timestamp);
        _attesterKilled[attester] = timestamp;
        emit AttesterKilled(attester, msg.sender, timestamp);
    }

    /// @inheritdoc IClearSigningRegistry
    function synchronizeRevocations(address attester, bytes32[] calldata attestationSetIds) external {
        address oracle = _revocationOracles[attester];
        if (oracle == address(0)) {
            return;
        }

        uint256 setCount = attestationSetIds.length;
        for (uint256 setIndex = 0; setIndex < setCount; setIndex++) {
            AttestationIdentifier[] storage members =
                _attestationSetContents[attester][attestationSetIds[setIndex]];
            uint256 memberCount = members.length;
            for (uint256 memberIndex = 0; memberIndex < memberCount; memberIndex++) {
                AttestationIdentifier storage member = members[memberIndex];
                if (_queryRevocationOracle(oracle, attester, member.attestationId, member.attestationFormatId)) {
                    _recordRevocation(attester, member.attestationId);
                }
            }
        }
    }

    /// @dev Gas-capped, return-size-capped 'staticcall' to an external revocation oracle.
    ///      Copies at most 32 bytes of return data regardless of what the callee returns, so
    ///      a malicious oracle cannot grief this call with an oversized return buffer. Any
    ///      revert, out-of-gas, or malformed (too-short) return is treated as 'false' — this
    ///      function never reverts because of a misbehaving oracle. A 'staticcall' is
    ///      inherently reentrancy-immune: no state mutation is possible anywhere in its
    ///      subtree, so an attacker-controlled oracle can supply a wrong answer but cannot
    ///      leverage reentrancy.
    function _queryRevocationOracle(
        address oracle,
        address attester,
        bytes32 attestationId,
        bytes32 attestationFormatId
    ) private view returns (bool revoked) {
        bytes memory callData = abi.encodeWithSelector(
            IRevocationOracle.isRevoked.selector, attester, attestationId, attestationFormatId
        );
        bool success;
        bytes32 result;
        uint256 gasStipend = REVOCATION_ORACLE_GAS_STIPEND;
        assembly {
            let scratch := mload(0x40)
            success := staticcall(gasStipend, oracle, add(callData, 0x20), mload(callData), scratch, 0x20)
            if and(success, iszero(lt(returndatasize(), 0x20))) {
                result := mload(scratch)
            }
        }
        return result != bytes32(0);
    }

    /// @inheritdoc IClearSigningRegistry
    function getRevocationTimestamp(address attester, bytes32 attestationId) external view returns (uint64) {
        uint64 individual = _revokedAt[attester][attestationId];
        return individual != 0 ? individual : _attesterKilled[attester];
    }

    /// @dev Records 'attestationId' as revoked under 'attester', emitting 'AttestationRevoked'.
    ///      Revoking an already-revoked ID keeps the original timestamp: the recorded
    ///      value is when the ID *first* became revoked, and must not move on a
    ///      repeated revocation.
    function _recordRevocation(address attester, bytes32 attestationId) private {
        if (_revokedAt[attester][attestationId] != 0) {
            return;
        }
        uint64 timestamp = uint64(block.timestamp);
        _revokedAt[attester][attestationId] = timestamp;
        emit AttestationRevoked(attester, attestationId, timestamp);
    }

    /// @dev Records 'attestationId' as revoked under 'attester' and clears 'contextKeyIds'
    ///      immediately wherever they still point to it. A context ID whose active set
    ///      has since moved to a different attestation set ID is silently skipped. Reached
    ///      via '_processRevocations' from both 'createAttestations' and 'revokeAttestations'.
    function _revokeAndClear(address attester, bytes32 attestationId, bytes32[] calldata contextKeyIds) private {
        if (attestationId == bytes32(0)) {
            revert ZeroAttestationId();
        }
        _recordRevocation(attester, attestationId);

        // An attestation set's schema MAJOR is intrinsic: set metadata is write-once, so
        // it is read from the stored details rather than passed in. An individual
        // attestation ID or a never-registered ID reads a schema MAJOR of 0, which no
        // active record can hold (registration forbids a zero descriptorSchemaMajor), so its
        // clearing loop is a natural no-op while the revocation itself is still recorded.
        uint256 descriptorSchemaMajor = _attestationSetDetails[attester][attestationId].descriptorSchemaMajor;

        uint256 contextKeyIdCount = contextKeyIds.length;
        for (uint256 contextKeyIndex = 0; contextKeyIndex < contextKeyIdCount; contextKeyIndex++) {
            bytes32 contextKeyId = contextKeyIds[contextKeyIndex];
            if (_activeAttestationSetIds[attester][contextKeyId][descriptorSchemaMajor] == attestationId) {
                _activeAttestationSetIds[attester][contextKeyId][descriptorSchemaMajor] = bytes32(0);
                emit AttestationUpdated(attester, contextKeyId, bytes32(0), attestationId, bytes32(0), descriptorSchemaMajor);
            }
        }
    }

    /// @inheritdoc IClearSigningRegistry
    function resolveDescriptors(
        address[] calldata attesters,
        bytes32[] calldata contextKeyIds,
        uint256[] calldata descriptorSchemaMajors,
        bytes32[] calldata attestationFormatIds,
        string[]  calldata allowedPrefixes
    ) external view returns (ResolvedDescriptor[] memory resolved) {
        uint256 activeRecordCount = _countActiveRecords(attesters, contextKeyIds, descriptorSchemaMajors);
        resolved = new ResolvedDescriptor[](activeRecordCount);
        _collectResolvedDescriptors(attesters, contextKeyIds, descriptorSchemaMajors, attestationFormatIds, allowedPrefixes, resolved);
    }

    /// @dev Counts the active records among the queried (attester, contextKeyId, descriptorSchemaMajor)
    ///      keys, used to size the 'resolveDescriptors' result array.
    function _countActiveRecords(
        address[] calldata attesters,
        bytes32[] calldata contextKeyIds,
        uint256[] calldata descriptorSchemaMajors
    ) private view returns (uint256 activeRecordCount) {
        for (uint256 attesterIndex = 0; attesterIndex < attesters.length; attesterIndex++) {
            address attester = attesters[attesterIndex];
            for (uint256 contextKeyIndex = 0; contextKeyIndex < contextKeyIds.length; contextKeyIndex++) {
                bytes32 contextKeyId = contextKeyIds[contextKeyIndex];
                for (uint256 majorIndex = 0; majorIndex < descriptorSchemaMajors.length; majorIndex++) {
                    if (_activeAttestationSetIds[attester][contextKeyId][descriptorSchemaMajors[majorIndex]] != bytes32(0)) {
                        ++activeRecordCount;
                    }
                }
            }
        }
    }

    /// @dev Fills 'resolved' with one entry per active (attester, contextKeyId, descriptorSchemaMajor) record.
    function _collectResolvedDescriptors(
        address[]            calldata attesters,
        bytes32[]            calldata contextKeyIds,
        uint256[]            calldata descriptorSchemaMajors,
        bytes32[]            calldata attestationFormatIds,
        string[]             calldata allowedPrefixes,
        ResolvedDescriptor[]   memory resolved
    ) private view {
        uint256 resolvedIndex;
        for (uint256 attesterIndex = 0; attesterIndex < attesters.length; attesterIndex++) {
            for (uint256 contextKeyIndex = 0; contextKeyIndex < contextKeyIds.length; contextKeyIndex++) {
                resolvedIndex = _resolveRecordsForContext(
                    attesters[attesterIndex], contextKeyIds[contextKeyIndex],
                    descriptorSchemaMajors, attestationFormatIds, allowedPrefixes, resolved, resolvedIndex
                );
            }
        }
    }

    /// @dev Resolves every schema MAJOR with an active record for one (attester, contextKeyId)
    ///      pair into 'resolved' starting at 'resolvedIndex', returning the index after the
    ///      last write.
    function _resolveRecordsForContext(
        address              attester,
        bytes32              contextKeyId,
        uint256[]   calldata descriptorSchemaMajors,
        bytes32[]   calldata attestationFormatIds,
        string[]    calldata allowedPrefixes,
        ResolvedDescriptor[] memory resolved,
        uint256              resolvedIndex
    ) private view returns (uint256) {
        for (uint256 majorIndex = 0; majorIndex < descriptorSchemaMajors.length; majorIndex++) {
            uint256 descriptorSchemaMajor      = descriptorSchemaMajors[majorIndex];
            bytes32 attestationSetId = _activeAttestationSetIds[attester][contextKeyId][descriptorSchemaMajor];
            if (attestationSetId != bytes32(0)) {
                resolved[resolvedIndex++] = _resolveActiveRecord(
                    attester, contextKeyId, descriptorSchemaMajor, attestationSetId, attestationFormatIds, allowedPrefixes
                );
            }
        }
        return resolvedIndex;
    }

    /// @dev Resolves one active attestation set into a ResolvedDescriptor.
    function _resolveActiveRecord(
        address            attester,
        bytes32            contextKeyId,
        uint256            descriptorSchemaMajor,
        bytes32            attestationSetId,
        bytes32[] calldata attestationFormatIds,
        string[]  calldata allowedPrefixes
    ) private view returns (ResolvedDescriptor memory) {
        AttestationSetDetails storage details = _attestationSetDetails[attester][attestationSetId];
        bytes32 descriptorMirrorListId  = _descriptorMirrorListIds[attester][details.descriptorHash];
        bytes32 attestationMirrorListId = _attestationMirrorListIds[attester][attestationSetId];

        return ResolvedDescriptor({
            descriptorHash:            details.descriptorHash,
            contextKeyId:                 contextKeyId,
            descriptorSchemaMajor:               descriptorSchemaMajor,
            attestationSetId:          attestationSetId,
            descriptorMirrorListUris:  _mirrorLists[descriptorMirrorListId].filter(allowedPrefixes),
            attestationMirrorListUris: _mirrorLists[attestationMirrorListId].filter(allowedPrefixes),
            attestations:              _resolveAttestations(attester, attestationSetId, attestationFormatIds)
        });
    }

    /// @dev Builds the format-filtered ResolvedAttestation array of one attestation set.
    function _resolveAttestations(
        address            attester,
        bytes32            attestationSetId,
        bytes32[] calldata attestationFormatIds
    ) private view returns (ResolvedAttestation[] memory attestations) {
        AttestationIdentifier[] storage contents = _attestationSetContents[attester][attestationSetId];

        uint256 matchCount;
        for (uint256 entryIndex = 0; entryIndex < contents.length; entryIndex++) {
            if (_matchesFormatFilter(contents[entryIndex].attestationFormatId, attestationFormatIds)) {
                ++matchCount;
            }
        }

        // Read once per resolved descriptor (this function runs once per active record),
        // not once per attestation — the fallback below is a single extra SLOAD either way.
        uint64 killedAt = _attesterKilled[attester];

        attestations = new ResolvedAttestation[](matchCount);
        uint256 outIndex;
        for (uint256 entryIndex = 0; entryIndex < contents.length; entryIndex++) {
            AttestationIdentifier storage entry = contents[entryIndex];
            if (!_matchesFormatFilter(entry.attestationFormatId, attestationFormatIds)) {
                continue;
            }
            uint64 individualRevokedAt = _revokedAt[attester][entry.attestationId];
            attestations[outIndex++] = ResolvedAttestation({
                attester:      attester,
                attestationId: entry.attestationId,
                attestationFormatId:      entry.attestationFormatId,
                revokedAt:     individualRevokedAt != 0 ? individualRevokedAt : killedAt
            });
        }
    }

    /// @dev Whether 'attestationFormatId' passes the 'attestationFormatIds' request filter; an empty filter passes all.
    function _matchesFormatFilter(bytes32 attestationFormatId, bytes32[] calldata attestationFormatIds) private pure returns (bool) {
        if (attestationFormatIds.length == 0) {
            return true;
        }
        for (uint256 filterIndex = 0; filterIndex < attestationFormatIds.length; filterIndex++) {
            if (attestationFormatIds[filterIndex] == attestationFormatId) {
                return true;
            }
        }
        return false;
    }

    /// @inheritdoc IClearSigningRegistry
    function getMirrorListById(bytes32 mirrorListId, string[] calldata allowedPrefixes)
        external view returns (string[] memory)
    {
        return _mirrorLists[mirrorListId].filter(allowedPrefixes);
    }

    /// @inheritdoc IClearSigningRegistry
    function getNonce(address attester) external view returns (uint256) {
        return _nonces[attester];
    }

    /// @inheritdoc IClearSigningRegistry
    function updateDescriptorMirrorList(
        address attester,
        bytes32[] calldata descriptorHashes,
        bytes32 descriptorMirrorListId,
        bytes calldata signature
    ) external {
        if (descriptorHashes.length == 0) {
            revert EmptyKeys();
        }
        _requireMirrorListPublished(descriptorMirrorListId);
        _authorizeMirrorListUpdate(
            attester, descriptorHashes, descriptorMirrorListId,
            ClearSigningRegistryConstants.DESCRIPTOR_MIRROR_UPDATE_TYPEHASH, signature
        );

        for (uint256 i = 0; i < descriptorHashes.length; i++) {
            bytes32 descriptorHash = descriptorHashes[i];
            // Registration always sets a non-zero descriptor MirrorList pointer, so a zero
            // pointer means the attester never registered this descriptor hash.
            if (_descriptorMirrorListIds[attester][descriptorHash] == bytes32(0)) {
                revert UnknownDescriptor(descriptorHash);
            }
            _setDescriptorMirrorList(attester, descriptorHash, descriptorMirrorListId);
        }
    }

    /// @inheritdoc IClearSigningRegistry
    function updateAttestationMirrorList(
        address attester,
        bytes32[] calldata attestationSetIds,
        bytes32 attestationMirrorListId,
        bytes calldata signature
    ) external {
        if (attestationSetIds.length == 0) {
            revert EmptyKeys();
        }
        _requireMirrorListPublished(attestationMirrorListId);
        _authorizeMirrorListUpdate(
            attester, attestationSetIds, attestationMirrorListId,
            ClearSigningRegistryConstants.ATTESTATION_MIRROR_UPDATE_TYPEHASH, signature
        );

        for (uint256 i = 0; i < attestationSetIds.length; i++) {
            bytes32 attestationSetId = attestationSetIds[i];
            if (_attestationSetDetails[attester][attestationSetId].descriptorHash == bytes32(0)) {
                revert UnknownAttestationSet(attestationSetId);
            }
            _setAttestationMirrorList(attester, attestationSetId, attestationMirrorListId);
        }
    }

    /// @dev Consumes a nonce and verifies the attester's EIP-712 MirrorList update
    ///      signature for relayed updates; a no-op when the attester submits directly.
    function _authorizeMirrorListUpdate(
        address            attester,
        bytes32[] calldata keys,
        bytes32            mirrorListId,
        bytes32            typeHash,
        bytes     calldata signature
    ) private {
        if (msg.sender == attester) {
            return;
        }
        uint256 nonce = _nonces[attester];
        _nonces[attester] = nonce + 1;
        _verifyMirrorUpdateSignature(attester, keys, mirrorListId, nonce, typeHash, signature);
    }

    /// @dev Points 'attester''s MirrorList for 'descriptorHash' at 'mirrorListId',
    ///      emitting an event only when the pointer actually changes.
    function _setDescriptorMirrorList(address attester, bytes32 descriptorHash, bytes32 mirrorListId) private {
        if (_descriptorMirrorListIds[attester][descriptorHash] == mirrorListId) {
            return;
        }
        _descriptorMirrorListIds[attester][descriptorHash] = mirrorListId;
        emit DescriptorMirrorListUpdated(attester, descriptorHash, mirrorListId);
    }

    /// @dev Points 'attester''s MirrorList for 'attestationSetId' at 'mirrorListId',
    ///      emitting an event only when the pointer actually changes.
    function _setAttestationMirrorList(address attester, bytes32 attestationSetId, bytes32 mirrorListId) private {
        if (_attestationMirrorListIds[attester][attestationSetId] == mirrorListId) {
            return;
        }
        _attestationMirrorListIds[attester][attestationSetId] = mirrorListId;
        emit AttestationMirrorListUpdated(attester, attestationSetId, mirrorListId);
    }

    // =========================================================================
    // Internal helpers
    // =========================================================================

    /// @dev Processes one descriptor of a registration batch: field validation,
    ///      MirrorList pointer updates, attestation set storage and
    ///      active-attestation-set updates.
    function _processDescriptor(
        address                 attester,
        DescriptorInfo calldata descriptor,
        bytes32                 descriptorMirrorListId,
        bytes32                 attestationMirrorListId
    ) private {
        _validateDescriptor(attester, descriptor);

        bytes32 attestationSetId = _deriveAttestationSetId(descriptor);

        _setDescriptorMirrorList(attester, descriptor.descriptorHash, descriptorMirrorListId);
        _storeAttestationSet(attester, attestationSetId, descriptor);
        _setAttestationMirrorList(attester, attestationSetId, attestationMirrorListId);

        _updateActiveAttestation(attester, descriptor, attestationSetId);
    }

    /// @dev Validates one descriptor's fields and every entry of its attestation set.
    function _validateDescriptor(address attester, DescriptorInfo calldata descriptor) private view {
        if (descriptor.descriptorHash == bytes32(0)) {
            revert ZeroDescriptorHash();
        }
        if (descriptor.descriptorSchemaMajor == 0) {
            revert ZeroDescriptorSchemaMajor();
        }
        if (descriptor.contextKeyIds.length == 0) {
            revert EmptyContextKeyIds();
        }
        AttestationIdentifier[] calldata attestationIds = descriptor.attestationIds;
        if (attestationIds.length == 0) {
            revert EmptyAttestationIds();
        }
        for (uint256 entryIndex = 0; entryIndex < attestationIds.length; entryIndex++) {
            AttestationIdentifier calldata entry = attestationIds[entryIndex];
            if (entry.attestationId == bytes32(0)) {
                revert ZeroAttestationId();
            }
            if (entry.attestationFormatId == bytes32(0)) {
                revert ZeroAttestationFormat();
            }
            // A revoked ID is consumed forever and cannot re-enter a set.
            if (_revokedAt[attester][entry.attestationId] != 0) {
                revert AttestationIdAlreadyUsed(entry.attestationId);
            }
            // One attestation per format per descriptor, so the index file's
            // format-to-attestation map stays unambiguous.
            for (uint256 earlierIndex = 0; earlierIndex < entryIndex; earlierIndex++) {
                if (attestationIds[earlierIndex].attestationFormatId == entry.attestationFormatId) {
                    revert DuplicateAttestationFormat(entry.attestationFormatId);
                }
            }
        }
    }

    /// @dev The attestation set ID of 'descriptor'. A single-attestation set uses the
    ///      sole member's own ID — in the common single-EAS case wallets address the set
    ///      directly by the ERC-8176 UID — while a larger set uses a content hash that
    ///      commits to the descriptor identity and the full member list.
    function _deriveAttestationSetId(DescriptorInfo calldata descriptor) private pure returns (bytes32) {
        AttestationIdentifier[] calldata attestationIds = descriptor.attestationIds;
        if (attestationIds.length == 1) {
            return attestationIds[0].attestationId;
        }
        return keccak256(abi.encode(descriptor.descriptorHash, descriptor.descriptorSchemaMajor, attestationIds));
    }

    /// @dev Stores one attestation set's write-once metadata and contents, or verifies
    ///      them against the stored record when the set ID is already registered (a
    ///      re-activation for more context IDs). A revoked set ID is consumed forever
    ///      and can never be registered again.
    function _storeAttestationSet(
        address                 attester,
        bytes32                 attestationSetId,
        DescriptorInfo calldata descriptor
    ) private {
        if (_revokedAt[attester][attestationSetId] != 0) {
            revert AttestationIdAlreadyUsed(attestationSetId);
        }

        AttestationSetDetails storage details = _attestationSetDetails[attester][attestationSetId];
        if (details.descriptorHash != bytes32(0)) {
            // The singleton shortcut makes a set ID attester-chosen, so the ID alone does
            // not commit to what it names — the stored record must match the incoming
            // descriptor before the set may be reused. (Content-derived multi-set IDs
            // match by construction; checking uniformly costs little.)
            _requireMatchingSet(attester, attestationSetId, descriptor, details);
            return;
        }

        details.descriptorHash = descriptor.descriptorHash;
        details.descriptorSchemaMajor    = descriptor.descriptorSchemaMajor;

        AttestationIdentifier[] calldata attestationIds = descriptor.attestationIds;
        AttestationIdentifier[] storage  contents       = _attestationSetContents[attester][attestationSetId];
        for (uint256 entryIndex = 0; entryIndex < attestationIds.length; entryIndex++) {
            contents.push(attestationIds[entryIndex]);
        }

        emit AttestationRegistered(
            attester, attestationSetId, descriptor.descriptorHash, descriptor.descriptorSchemaMajor, attestationIds
        );
    }

    /// @dev Reverts with 'AttestationIdAlreadyUsed' unless the stored record of
    ///      'attestationSetId' matches 'descriptor' exactly (details and member list,
    ///      order-sensitive like the set ID derivation).
    function _requireMatchingSet(
        address                       attester,
        bytes32                       attestationSetId,
        DescriptorInfo       calldata descriptor,
        AttestationSetDetails storage details
    ) private view {
        AttestationIdentifier[] calldata attestationIds = descriptor.attestationIds;
        AttestationIdentifier[] storage  contents       = _attestationSetContents[attester][attestationSetId];

        bool matches = details.descriptorHash == descriptor.descriptorHash
            && details.descriptorSchemaMajor == descriptor.descriptorSchemaMajor
            && contents.length == attestationIds.length;
        if (matches) {
            for (uint256 entryIndex = 0; entryIndex < attestationIds.length; entryIndex++) {
                if (contents[entryIndex].attestationId != attestationIds[entryIndex].attestationId
                    || contents[entryIndex].attestationFormatId != attestationIds[entryIndex].attestationFormatId) {
                    matches = false;
                    break;
                }
            }
        }
        if (!matches) {
            revert AttestationIdAlreadyUsed(attestationSetId);
        }
    }

    /// @dev Verifies the attester's EIP-712 signature over a registration batch.
    ///      Binding both MirrorList IDs prevents a relayer from substituting different
    ///      MirrorLists; the nonce makes the signature single-use. Revocation is a
    ///      separate, independently-signed 'revokeAttestations' action, so no
    ///      revocation data is bound here.
    function _verifyRegistrationSignature(
        address                    attester,
        DescriptorInfo[]  calldata descriptors,
        bytes32                    descriptorMirrorListId,
        bytes32                    attestationMirrorListId,
        uint256                    nonce,
        bytes             calldata signature
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                ClearSigningRegistryConstants.REGISTRATION_BATCH_TYPEHASH,
                RegistrationHashLib.hashDescriptorInfos(descriptors),
                descriptorMirrorListId,
                attestationMirrorListId,
                nonce
            )
        );
        _verifySignature(attester, structHash, signature);
    }

    /// @dev Verifies the attester's EIP-712 signature over a standalone revocation batch.
    function _verifyRevocationSignature(
        address                    attester,
        RevocationEntry[] calldata revocations,
        uint256                    nonce,
        bytes             calldata signature
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                ClearSigningRegistryConstants.REVOCATION_BATCH_TYPEHASH,
                RegistrationHashLib.hashRevocationEntries(revocations),
                nonce
            )
        );
        _verifySignature(attester, structHash, signature);
    }

    /// @dev Verifies the attester's EIP-712 signature over a profile/config update.
    function _verifyProfileUpdateSignature(
        address         attester,
        string calldata profileURI,
        address         revocationOracle,
        address         killSwitchKey,
        uint256         nonce,
        bytes  calldata signature
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                ClearSigningRegistryConstants.ATTESTER_PROFILE_UPDATE_TYPEHASH,
                keccak256(bytes(profileURI)),
                revocationOracle,
                killSwitchKey,
                nonce
            )
        );
        _verifySignature(attester, structHash, signature);
    }

    /// @dev Verifies that 'killSwitchKey' itself signed a 'KillSwitchBinding' naming
    ///      'attester' — proof of control and consent, independent of who submitted the
    ///      'setAttesterProfile' call. Uses a dedicated error rather than '_verifySignature'
    ///      (which always reverts as 'InvalidRegistrationSignature') so a binding failure is
    ///      distinguishable from an attester-signature failure.
    function _verifyKillSwitchBinding(
        address attester,
        address killSwitchKey,
        uint256 nonce,
        bytes calldata killSwitchSignature
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(ClearSigningRegistryConstants.KILL_SWITCH_BINDING_TYPEHASH, attester, killSwitchKey, nonce)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(killSwitchKey, digest, killSwitchSignature)) {
            revert InvalidKillSwitchSignature();
        }
    }

    /// @dev Verifies the attester's EIP-712 mirror update signature.
    function _verifyMirrorUpdateSignature(
        address              attester,
        bytes32[]   calldata keys,
        bytes32              mirrorListId,
        uint256              nonce,
        bytes32              typeHash,
        bytes       calldata signature
    ) private view {
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                keccak256(abi.encodePacked(keys)),
                mirrorListId,
                nonce
            )
        );
        _verifySignature(attester, structHash, signature);
    }

    /// @dev Verifies an EIP-712 signature over the given struct hash via ECDSA
    ///      recovery for EOA attesters and ERC-1271 for contract attesters.
    function _verifySignature(
        address        attester,
        bytes32        structHash,
        bytes calldata signature
    ) private view {
        bytes32 digest = _hashTypedDataV4(structHash);
        if (!SignatureChecker.isValidSignatureNow(attester, digest, signature)) {
            revert InvalidRegistrationSignature();
        }
    }

    /// @dev Records each entry in 'revocations' as revoked under 'attester' and clears
    ///      its listed context IDs. Safe to call with an empty array when no attestation
    ///      sets are being displaced.
    function _processRevocations(address attester, RevocationEntry[] calldata revocations) private {
        uint256 revocationCount = revocations.length;
        for (uint256 revocationIndex = 0; revocationIndex < revocationCount; revocationIndex++) {
            RevocationEntry calldata entry = revocations[revocationIndex];
            _revokeAndClear(attester, entry.attestationId, entry.contextKeyIds);
        }
    }

}
