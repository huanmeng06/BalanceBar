# Automatic update recovery

BalanceBar keeps the previous app bundle until the replacement reaches
`applicationDidFinishLaunching`. If the system refuses to launch the new app,
the updater leaves the backup in place for manual recovery.

The backup is stored at:

`~/Library/Application Support/<bundle identifier>/Updater/Backups/BalanceBar.previous-<version>.app`

To restore it, quit BalanceBar, open Finder, and choose **Go → Go to Folder**.
Enter `~/Library/Application Support/<bundle identifier>/Updater/Backups/`.
Copy the `BalanceBar.previous-<version>.app` bundle back to the location where
BalanceBar is installed, replacing the failed `BalanceBar.app`. Keep the backup
until the restored app has opened successfully.

If BalanceBar reaches its startup code but exits before
`applicationDidFinishLaunching`, the next launch attempt restores the previous
bundle and exits. Open BalanceBar again to start the restored version. If macOS
refuses to start the new executable before that code runs, use the Finder steps
above.

Manual in-app installs keep their rollback bundle beside the installed app as
`.BalanceBar.previous-<unique id>.app` until the replacement reaches
`applicationDidFinishLaunching`.

## Development-bundle end-to-end check

Use a separate `BalanceBar Dev.app` and a disposable asset directory. Create a
test Ed25519 key pair outside the repository, sign a schema-1 manifest with key
ID `dev-test`, and build a DMG whose `BalanceBar.app` has the same development
bundle identifier and a version higher than the running app. Place the DMG,
manifest, signature, and a GitHub-release-shaped JSON fixture in the asset
directory. The fixture's asset URLs use the repository's normal GitHub release
download path, while the development-only downloader reads those asset names
locally.

Launch the development executable with `BALANCEBAR_RELEASE_FIXTURE_PATH`,
`BALANCEBAR_UPDATE_ASSET_DIRECTORY`, and `BALANCEBAR_UPDATE_TEST_PUBLIC_KEY`
set. Enable automatic updates, wait for the verified-ready status, then choose
**Quit BalanceBar** from the menu. Confirm that the app stays closed. Launch the
development app again and confirm the DMG version is running. Close the
Dashboard window separately to confirm it does not start installation.
