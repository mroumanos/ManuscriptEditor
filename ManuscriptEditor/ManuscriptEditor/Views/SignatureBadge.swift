// SignatureBadge.swift
//
// The reusable identity chip shown wherever a person's name appears on an
// action (version stamps, comments, author lists):
//
//   ✓ green   — the signature verifies AND the key is tied to a manuscript
//               author → shows the AUTHOR's name (not the raw signer name)
//   ? orange  — the signature verifies but the key isn't tied to any author
//               → shows the signer name (usually their system user name)
//   ✗ red     — a signature is present but does not authenticate
//   (nothing) — unsigned (older data, or no identity configured)

import SwiftUI

struct SignatureBadge: View {

    /// Raw signer name recorded with the action (usually the system name).
    let signerName: String
    /// The signer's public key (base64), if the action was signed.
    var signerKey: String? = nil
    /// The exact message that was signed (see SigningService conventions).
    var message: String? = nil
    /// The signature (base64 DER), if any.
    var signature: String? = nil
    /// The manuscript's authors — keys tied here resolve to author names.
    var authors: [Author] = []

    private enum Verdict {
        case remoteVerified(String)   // ✓ signature checks AND identity is remote-anchored
        case localChecks(String)      // ? signature checks but only a local identity vouches
        case invalid                  // ! signature does not authenticate
        case unsigned
    }

    /// The tie for a key, searching rich `signatureInfos` first, then the
    /// legacy `publicKeys` list (treated as local identities).
    private func tie(for key: String) -> (author: Author, info: AuthorSignature?)? {
        for author in authors {
            if let info = (author.signatureInfos ?? []).first(where: { $0.publicKey == key }) {
                return (author, info)
            }
            if (author.publicKeys ?? []).contains(key) {
                return (author, nil)   // legacy tie = local
            }
        }
        return nil
    }

    private var verdict: Verdict {
        guard let signerKey, let message, let signature else { return .unsigned }
        guard SigningService.verify(message: message, signature: signature, publicKey: signerKey) else {
            return .invalid
        }
        if let (author, info) = tie(for: signerKey) {
            let name = author.fullName.isEmpty ? signerName : author.fullName
            // Green only when a REMOTE identity anchors the key; a local
            // identity can't prove who the editor is.
            if let info, info.type != IdentityType.local.rawValue, info.verified == true {
                return .remoteVerified(name)
            }
            return .localChecks(name)
        }
        return .localChecks(signerName)
    }

    var body: some View {
        switch verdict {
        case .remoteVerified(let name):
            HStack(spacing: 4) {
                Text(name)
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .help("Signature verified against a remote identity (GitHub/GitLab/OpenPGP)")
        case .localChecks(let name):
            HStack(spacing: 4) {
                Text(name)
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            }
            .help("Signature checks out, but only a local identity vouches for it — remote identities (Preferences → User) earn the green ✓")
        case .invalid:
            HStack(spacing: 4) {
                Text(signerName)
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            .help("Signature does NOT authenticate — the content or key doesn't match")
        case .unsigned:
            Text(signerName.isEmpty ? "—" : signerName)
        }
    }
}
