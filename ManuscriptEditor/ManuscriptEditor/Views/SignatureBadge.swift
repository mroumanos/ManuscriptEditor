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
        case verifiedAuthor(String)   // author display name
        case verifiedUntied           // valid signature, no author tie
        case invalid                  // signature fails verification
        case unsigned
    }

    private var verdict: Verdict {
        guard let signerKey, let message, let signature else { return .unsigned }
        guard SigningService.verify(message: message, signature: signature, publicKey: signerKey) else {
            return .invalid
        }
        if let author = authors.first(where: { ($0.publicKeys ?? []).contains(signerKey) }) {
            return .verifiedAuthor(author.fullName.isEmpty ? signerName : author.fullName)
        }
        return .verifiedUntied
    }

    var body: some View {
        switch verdict {
        case .verifiedAuthor(let name):
            HStack(spacing: 4) {
                Text(name)
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
            }
            .help("Signature verified — key is registered to this author")
        case .verifiedUntied:
            HStack(spacing: 4) {
                Text(signerName)
                Image(systemName: "questionmark.circle").foregroundStyle(.orange)
            }
            .help("Signature verifies, but the key isn't tied to any author yet (tie it in Authors)")
        case .invalid:
            HStack(spacing: 4) {
                Text(signerName)
                Image(systemName: "xmark.seal.fill").foregroundStyle(.red)
            }
            .help("Signature does NOT authenticate — the content or key doesn't match")
        case .unsigned:
            Text(signerName.isEmpty ? "—" : signerName)
        }
    }
}
