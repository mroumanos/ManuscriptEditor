// UserIdentityView.swift
//
// Preferences → User: the local identity used to attribute manuscript
// activity.  The name defaults to the macOS account's full name; a P-256
// signing keypair is created automatically (private key in the Keychain,
// never in any manuscript file).  Every stamp and comment carries the public
// key + a signature; tying the public key to an author (Authors pane) makes
// activity display the author's name with a verified badge.

import SwiftUI
import AppKit

struct UserIdentityView: View {

    @State private var name = SigningService.userName
    @State private var publicKey = SigningService.publicKeyBase64 ?? ""
    @State private var confirmRegenerate = false

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Name", text: $name)
                    .onChange(of: name) { _, new in SigningService.userName = new }
                Text("Recorded on every version stamp and comment you make. Defaults to your macOS account name.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Signing Key") {
                LabeledContent("Public key") {
                    HStack(spacing: 8) {
                        Text(publicKey.isEmpty ? "unavailable" : publicKey)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(publicKey, forType: .string)
                        }
                        .controlSize(.small)
                        .disabled(publicKey.isEmpty)
                    }
                }
                Button("Regenerate Key…", role: .destructive) {
                    confirmRegenerate = true
                }
                Text("The private key lives in your Keychain and never enters manuscript files. The public key travels with your stamps/comments; tie it to an author in the Authors pane so your activity shows the author's name with a verified ✓.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog("Regenerate Signing Key?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) {
                SigningService.regenerateKey()
                publicKey = SigningService.publicKeyBase64 ?? ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Past signatures keep verifying against the old public key (if it was tied to an author), but new activity signs with the new key — you'll need to tie the new key to your author entry again.")
        }
    }
}
