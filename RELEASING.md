# Releasing

How a distribution build is produced and published to GitHub Releases.

## 1. Build the release artifact

```
./scripts/make-release.sh 0.1.0
```

This runs an `xcodebuild` Release build and produces
`dist/ManuscriptEditor-0.1.0.dmg` — a drag-to-Applications disk image
(the app plus an `/Applications` symlink in the mounted window).

The script does **not** commit or publish anything; `dist/` is gitignored —
binaries ship via GitHub Releases, never inside the repo.

## 2. Publish the release

With the [GitHub CLI](https://cli.github.com) (`brew install gh`, `gh auth login`):

```
gh release create v0.1.0 dist/ManuscriptEditor-0.1.0.dmg \
  --title "Manuscript Editor 0.1.0" \
  --notes-file dist/RELEASE_NOTES.md
```

Or upload the dmg manually: repository → Releases → "Draft a new release".

## Signing & notarization (current status: unsigned)

Release builds are currently ad-hoc signed; downloaders must right-click →
Open the first launch (Gatekeeper). For frictionless distribution later:

1. Enroll in the Apple Developer Program.
2. Sign with a Developer ID Application certificate
   (`CODE_SIGN_IDENTITY="Developer ID Application"` in the script).
3. Notarize: `xcrun notarytool submit dist/….dmg --keychain-profile <profile> --wait`
   then staple: `xcrun stapler staple ManuscriptEditor.app`.
