// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title  IRevocationOracle — Generic pull-based revocation source for 'synchronizeRevocations'
/// @notice The entire vocabulary the registry has for an external attestation-lifecycle
///         protocol. An attester opts a given attestation format into external revocation
///         sync by registering an implementation of this interface as their
///         'revocationOracle' — see 'setAttesterProfile' and 'synchronizeRevocations' in
///         'IClearSigningRegistry'. The registry itself never names or assumes any
///         specific external protocol (e.g. EAS); an oracle backed by one is implementation
///         detail entirely outside this ERC's normative text.
interface IRevocationOracle {
    /// @notice Whether 'attestationId' — of the stated format, issued by 'attester' — is
    ///         considered revoked by this oracle's external source of truth.
    ///
    ///         Called via a gas-capped, return-size-capped 'staticcall' from
    ///         'synchronizeRevocations'. Implementations MUST be side-effect-free (the
    ///         call context enforces this) and SHOULD return promptly: a revert,
    ///         out-of-gas, or malformed return is treated by the caller as 'false'.
    ///
    /// @param attester           The attester who issued the attestation.
    /// @param attestationId      The attestation ID being queried.
    /// @param attestationFormatId  The attestation's format ID, letting one oracle serve
    ///                           multiple formats by branching internally.
    /// @return revoked  True if the external source considers this attestation revoked.
    function isRevoked(address attester, bytes32 attestationId, bytes32 attestationFormatId)
        external view returns (bool revoked);
}
