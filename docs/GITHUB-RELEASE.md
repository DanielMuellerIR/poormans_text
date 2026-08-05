# GitHub release procedure

The distributable files are built and notarized locally because signing and
notarization credentials are intentionally not stored in GitHub Actions.

## Repository metadata

Suggested description:

> Convert word-processing documents and spreadsheets to Markdown on macOS.

Suggested topics:

`macos`, `swift`, `markdown`, `rtf`, `rtfd`, `docx`, `odt`, `ods`, `xlsx`,
`xls`, `pandoc`, `document-conversion`

## Release checklist

1. Confirm that public contact and legal-notice requirements have been resolved
   for the intended form of publication. Never commit a private address merely
   to satisfy this checklist.
2. Confirm that the author name, email address, and full Git history are intended
   to be public. Rewriting history requires a separate, explicit decision.
3. Run `swift test` and `./build.sh release` from a clean checkout.
4. Commit the intended release state and create the annotated `v0.7.0` tag.
5. Run `./install.sh --with-dmg`. One run builds, signs, and notarizes the app,
   packs and notarizes the DMG, writes its checksum, and installs the app and
   the CLI link — all from the same signed bundle. Do not split this into
   `./release.sh` plus `./install.sh`: two runs build and sign twice, so the
   repository app, the installed app, and the app inside the DMG no longer share
   a CodeDirectory hash and step 6 fails.
6. Run `scripts/verify_release.sh 0.7.0`. It requires the clean, exact release
   tag and independently checks the repository app, the installed app, the DMG,
   the checksum, and the CLI link — including that all three app copies carry
   the same CodeDirectory hash.
7. Perform the public privacy and secret scan over the exact outgoing commit and
   the complete history intended for publication.
8. Only after explicit publication approval, create the public remote, push
   `main` and the tag, enable secret scanning, push protection, Issues, and
   private vulnerability reporting, and wait for CI to pass.
9. Create a draft GitHub release from the exact tag:

    ```sh
    gh release create v0.7.0 \
      Poor-Mans-Text-0.7.0.dmg \
      Poor-Mans-Text-0.7.0.dmg.sha256 \
      --verify-tag \
      --draft \
      --title "Poor Man's Text 0.7.0" \
      --notes-file docs/releases/0.7.0.md
    ```

Download the draft assets again, verify the checksum, and only then publish the
draft. No unsigned, ad-hoc-signed, or merely Developer-ID-signed build may be
uploaded as the release application.

10. Publishing the release starts `.github/workflows/publish-appcast.yml`, which
    signs the Sparkle appcast and deploys it to GitHub Pages. Check the workflow
    and fetch the feed afterwards; an older installed build must find, install,
    and restart into the new version. The release notes of this exact release are
    what Sparkle shows in its update dialog. The German
    [SPARKLE-RELEASE.md](SPARKLE-RELEASE.md) describes the one-time setup, the
    key handling, and this step in detail.
