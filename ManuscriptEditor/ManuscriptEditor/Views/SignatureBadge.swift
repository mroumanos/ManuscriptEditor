// SignatureBadge.swift
//
// The reusable identity chip shown wherever an editor's name appears on an
// action (version stamps, comments, the Overview editors list).  Editors are
// deliberately decoupled from manuscript authors — the badge judges the
// artifact on its own signature + the identity type recorded with it:
//
//   ✓ green   — the signature verifies AND the signer used a remote-verified
//               identity (GitHub / GitLab / OpenPGP)
//   ? orange  — the signature verifies but only a local identity vouches
//   ! red     — a signature is present but does not authenticate
//   (nothing) — unsigned (older data, or no identity configured)

import SwiftUI

struct SignatureBadge: View {

    /// Signer name recorded with the action.
    let signerName: String
    /// The signer's public key (base64), if the action was signed.
    var signerKey: String? = nil
    /// Identity type recorded at signing time (IdentityType raw value).
    var signerType: String? = nil
    /// Where the signing key came from, as recorded on the artifact —
    /// "GitHub (mroumanos)", "OpenPGP (A1B2C3D4)", "Local key".
    var signerSource: String? = nil
    /// The exact message that was signed (see SigningService conventions).
    var message: String? = nil
    /// The signature (base64 DER), if any.
    var signature: String? = nil

    private enum Verdict {
        case remoteVerified   // ✓
        case localChecks      // ?
        case invalid          // !
        case unsigned
    }

    private var verdict: Verdict {
        guard let signerKey, let message, let signature else { return .unsigned }
        guard SigningService.verify(message: message, signature: signature, publicKey: signerKey) else {
            return .invalid
        }
        if let signerType, signerType != IdentityType.local.rawValue {
            return .remoteVerified
        }
        return .localChecks
    }

    /// The key's source, preferring what the artifact recorded over anything
    /// the app currently believes: a stamp from a year ago was signed by
    /// whatever vouched for it then.
    private var sourceDescription: String {
        if let signerSource, !signerSource.isEmpty { return "signed with: \(signerSource)" }
        guard let signerType, let type = IdentityType(rawValue: signerType) else {
            return "source not recorded"
        }
        return type == .local ? "signed with a local key" : "signed with a \(type.label) identity"
    }

    var body: some View {
        switch verdict {
        case .remoteVerified:
            HStack(spacing: 4) {
                Text(signerName)
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .help("Signature verified — \(sourceDescription)")
        case .localChecks:
            HStack(spacing: 4) {
                Text(signerName)
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            }
            .help("Signature checks out, but nothing vouches for who signed it — \(sourceDescription). Attach a GPG key or an account in Settings → User to earn the green ✓")
        case .invalid:
            HStack(spacing: 4) {
                Text(signerName)
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .help("Signature does NOT authenticate — the content or key doesn't match (\(sourceDescription))")
        case .unsigned:
            Text(signerName.isEmpty ? "—" : signerName)
        }
    }
}
