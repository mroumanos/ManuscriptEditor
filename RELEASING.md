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

## Signing & notarization

Release builds are signed with the **Developer ID Application** certificate
(Michael Roumanos, team `M72QBAW2TT`) with hardened runtime + timestamp; the
dmg is signed too. For zero-friction downloads, also notarize:

1. One-time: store notary credentials (uses an Apple ID app-specific
   password from appleid.apple.com):

   ```
   xcrun notarytool store-credentials ManuscriptEditor \
     --apple-id <appleid email> --team-id M72QBAW2TT
   ```

2. Every release: `NOTARY_PROFILE=ManuscriptEditor ./scripts/make-release.sh <version>`
   — the script submits, waits, and staples the dmg automatically.

Un-notarized signed builds still open, but macOS asks the user to approve
the first launch in System Settings → Privacy & Security.
