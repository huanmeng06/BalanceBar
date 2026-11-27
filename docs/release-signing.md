# Release signing

Each new stable or beta Release contains a DMG, an Ed25519-signed update
manifest, and the manifest signature. The release workflow publishes these
assets from a draft only after it downloads them again and verifies the
manifest signature and DMG size and SHA-256. The DMG also receives a GitHub
build provenance attestation. Older Releases without a manifest remain manual
installations.

## First-time setup

Generate a signing key on a trusted Mac with OpenSSL 3 or newer. Choose a path
outside this repository. The script refuses to overwrite a file and sets the
private key permissions to `600`.

```sh
mkdir -p "$HOME/.balancebar"
./scripts/release/generate-update-signing-key.sh "$HOME/.balancebar/bb-release-1.pem"
```

The script prints the public key and its `Info.plist` dictionary. Add that
dictionary to `BalanceBarUpdateSigningKeys` in `Resources/Info.plist`, commit
the public key, and configure the private key as the repository Actions secret.

```sh
gh secret set BALANCEBAR_UPDATE_SIGNING_KEY --repo huanmeng06/BalanceBar < "$HOME/.balancebar/bb-release-1.pem"
```

Back up the private key offline, such as in a password manager, then remove
the local copy. Never add the private key to the repository, a client build,
an artifact, or a log. A missing secret or a secret that does not match a
trusted public key stops publication.

## Rotating the key

Add the new public key to `BalanceBarUpdateSigningKeys` while retaining the
old key. Publish that version using the old private key so installed clients
learn to trust both keys. Then update the Actions secret to the new private
key for a later version. The signing step matches the secret's public key to
the trusted keys and selects its `keyId`. Keep both public keys in the app
until clients have had a chance to update.

If the private key is lost or exposed, installed older versions cannot
automatically verify releases signed by a replacement key they do not trust.
Users must install one version manually to receive the replacement public key.

## Verifying a release

Run ID is shown in the app's About page. Select it to open the matching GitHub
Actions run. To verify the provenance attestation for a downloaded DMG:

```sh
gh attestation verify BalanceBar-<version>.dmg --repo huanmeng06/BalanceBar
```

The attestation and displayed Run ID provide build transparency. The update
manifest's Ed25519 signature is the integrity check used by automatic updates.

## Recovering a draft after verification fails

If the draft asset verification step fails, the workflow leaves the draft
unpublished and the tag in place. A new run skips that version while either
exists.

1. Review the failed Release workflow logs and resolve the cause before
   retrying. Wait for any active Release runs to finish before cleanup.
2. In GitHub, confirm the Release for the failed version is still a draft
   and its tag points to the commit recorded by that run. Set `tag` to the
   verified tag and run the command below to delete the draft and tag. For a
   published Release, leave the Release and tag in place and issue a new
   version.

   ```sh
   gh release delete "$tag" --cleanup-tag --repo huanmeng06/BalanceBar
   ```
3. In the original Release workflow run, select **Re-run all jobs** so the
   plan checks for duplicates again and the DMG and manifest are generated
   in the same run attempt. Confirm draft verification succeeds before the
   workflow publishes the Release. If the fix requires a source change,
   publish a new version from the corrected source.

## Signed release immutability

A Release with an update manifest cannot be rebuilt. To correct it, publish a
new version. GitHub repository administrators can also enable Immutable
Releases in repository settings. This prevents edits and deletion after
publication at the repository level, while making emergency corrections and
asset cleanup less flexible. This project currently enforces immutability in
the release workflow and does not change repository settings.

## Future Developer ID signing and notarization

Developer ID signing and notarization are not configured. They require an
Apple Developer Program membership, a Developer ID Application certificate
stored in Actions Secrets, and notarization credentials for `notarytool`.
Those steps belong in the macOS `build-dmg` job after app packaging and before
DMG creation. The signed update manifest remains an independent release
integrity check.
