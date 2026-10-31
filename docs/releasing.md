# Releasing and in-app updates

WhatsApp Work updates itself from the
[latest GitHub release](https://github.com/ralfiannor/whatsapp-work/releases).
Builds are ad-hoc signed, which proves nothing about who built them, so
every release is also signed with the maintainer's **Ed25519 release
key**. The app ships the public half and installs nothing that fails to
verify against it.

## How the app updates

1. **Check.** 10 s after launch and every 12 h (Release builds only), or
   from **WhatsApp Work ▸ Check for Updates…**, the app asks GitHub for
   `releases/latest` (`WWUpdateFeedURL` in `Info.plist`).
2. **Download.** This only happens if the release is newer than the
   running version. The release must carry a `.dmg` and a matching
   `.dmg.sig`. An unsigned newer release is refused; an unsigned older or
   equal one just reads as "up to date".
3. **Verify, then stage.** These steps run in this order:
   - The DMG bytes must verify against `WWUpdatePublicKey`. Nothing is
     unpacked before this check passes.
   - The DMG is mounted read-only and its app is copied out.
   - The copied app must have the same bundle identifier and exactly the
     release's version, which rules out replaying an older signed image
     under a newer tag.
   - It must pass `codesign --verify --deep --strict`.
4. **Install.** The sidebar shows *“WhatsApp Work X is ready”* with
   **Restart**. The swap happens when the app quits, after the core has
   stopped:
   - The staged and installed bundles are exchanged atomically
     (`renamex_np(RENAME_SWAP)`), so there is never a moment without an
     app at the install path.
   - **Restart** reopens the app after the swap. A plain quit installs
     without reopening.

A copy that cannot replace itself (read-only location, App Translocation)
shows **Download**, which opens the release page instead.

## Cutting a release

```bash
# 1. Bump MARKETING_VERSION in apps/macos/project.yml (e.g. "0.2.0"),
#    update CHANGELOG.md, commit.
# 2. Build, package and sign:
./scripts/release.sh
# 3. Publish BOTH files (the script prints this command):
gh release create v0.2.0 dist/WhatsAppWork-0.2.0-universal.dmg \
  dist/WhatsAppWork-0.2.0-universal.dmg.sig --title "WhatsApp Work 0.2.0" --generate-notes
```

`release.sh` refuses to sign unless the built app has the expected
version and its embedded `WWUpdatePublicKey` matches the key in your
Keychain.

## The release key

The key is managed with `swift scripts/release-key.swift`:

- **`generate`** creates the key once and prints the public key. That
  value goes into `WWUpdatePublicKey` in
  `apps/macos/WhatsAppWork/Info.plist`. The command refuses to replace an
  existing key.
- **`public`** prints the public key again.
- **`sign <file>`** prints a base64 signature. `release.sh` uses this.

The private key lives only in the login Keychain, under the service
`dev.whatsappwork.release-signing`. It never goes into the repository,
CI logs or chat.

- **Back it up.** Store the output of
  `security find-generic-password -s dev.whatsappwork.release-signing -w`
  in a password manager.
- **If it is lost or leaked:**
  1. Generate a new key and ship it in a release.
  2. Installed copies still trust only the old key, so they cannot
     auto-update to that release. Users install it once by hand.
  3. A leaked key must be rotated immediately. Until then, whoever holds
     it can ship an update that installed copies will accept.

## Forks

A fork that publishes its own releases must point `WWUpdateFeedURL` at its
own repository and generate its own key. A build without a valid
`WWUpdatePublicKey` simply has the updater switched off.

## Testing the updater locally

For a local end-to-end test, `WW_UPDATE_FEED_URL` (an environment
variable, for example `open -n --env WW_UPDATE_FEED_URL=…`) points one
launch at a local feed that serves a `releases/latest`-shaped JSON file.
The signature check still applies.
