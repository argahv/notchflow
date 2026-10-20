# Releasing NotchFlow

A release is a universal app, signed with a **Developer ID**, notarized by Apple, and attached to a GitHub
Release as `NotchFlow-<version>.zip` with a SHA-256 checksum. People download, unzip and open it without
Gatekeeper warnings.

## One-time setup on your Mac

1. **Certificate.** In Xcode › Settings › Accounts, sign in with the Apple ID of your paid developer
   account, select the team, then **Manage Certificates… › + › Developer ID Application**. Only the
   account holder can create one.
2. **Notarization credentials.** Create an app-specific password at account.apple.com (Sign-In and
   Security), then run the following command. It asks for your Apple ID and the password, and stores them
   in your Keychain as the profile `notchflow`:

   ```bash
   bash Scripts/release.sh setup
   ```

3. **Check.** Each line should show ✓:

   ```bash
   bash Scripts/release.sh check
   ```

## Publish from your Mac

```bash
bash Scripts/release.sh publish 0.1.0
```

This refuses to run with uncommitted changes or an existing tag. It builds the universal app with that
version and build number, signs it with the hardened runtime, submits it for notarization and waits,
staples the ticket, and checks it with Gatekeeper (`spctl` must report *Notarized Developer ID*). Then it
zips the app, writes the checksum, pushes the tag `v0.1.0`, and creates the GitHub Release.

## Publish from GitHub Actions (optional)

**Actions › Release › Run workflow** with a version does the same on a macOS runner. Add these repository
secrets first (Settings › Secrets and variables › Actions):

| Secret | What |
|---|---|
| `DEVELOPER_ID_P12_BASE64` | Your Developer ID Application certificate *with its private key*, exported from Keychain Access as .p12, then `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_P12_PASSWORD` | The password you chose when exporting the .p12 |
| `NOTARY_KEY_P8_BASE64` | An App Store Connect API key (Users and Access › Integrations › Team Keys, role Developer), `base64 -i AuthKey_XXXX.p8 \| pbcopy` |
| `NOTARY_KEY_ID` | That key's ID |
| `NOTARY_ISSUER_ID` | The issuer ID shown above the keys list |

The workflow imports the certificate into a temporary keychain, which it deletes at the end. Secrets are
never printed or committed. It's started by hand, so it never races a release published from your Mac.

## Notes

- Entitlements: Apple Events (Music/Spotify control) and camera (Mirror). There's no sandbox, so the agent
  inbox, Downloads and hooks work as documented. The hardened runtime is on.
- `Scripts/notchflow.py` ships inside the app (Resources) and is signed with it. Hook commands copied from
  Settings point at that signed copy.
- Notarization usually takes a few minutes. If it's rejected, run
  `xcrun notarytool log <submission-id> --keychain-profile notchflow` to see why.
