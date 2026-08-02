# GitHub release procedure

The distributable files are built and notarized locally because signing and
notarization credentials are intentionally not stored in GitHub Actions.

## Repository metadata

Suggested description:

> Convert RTF, RTFD, DOCX, ODT, and DOC documents to Markdown with extracted images.

Suggested topics:

`macos`, `swift`, `markdown`, `rtf`, `rtfd`, `docx`, `odt`, `pandoc`,
`document-conversion`

## Release checklist

1. Confirm that public contact and legal-notice requirements have been resolved
   for the intended form of publication. Never commit a private address merely
   to satisfy this checklist.
2. Confirm that the author name, email address, and full Git history are intended
   to be public. Rewriting history requires a separate, explicit decision.
3. Run `swift test` and `./build.sh release` from a clean checkout.
4. Commit the intended release state and create the annotated `v0.6.0` tag.
5. Run `./release.sh`. It builds, signs, and notarizes the app, then packs and
   notarizes the DMG and writes its checksum. It never installs anything.
6. Run `./install.sh`. It repeats build, signing, and notarization and then
   installs the app and the CLI link. It never builds a DMG. Both entry points
   are the same script behind `--no-install` and `--no-dmg`, so the two runs are
   separate and both are required.
7. Run `scripts/verify_release.sh 0.6.0`. It requires the clean, exact release
   tag and independently checks the repository app, the installed app, the DMG,
   the checksum, and the CLI link — including that all three app copies carry
   the same CodeDirectory hash.
8. Perform the public privacy and secret scan over the exact outgoing commit and
   the complete history intended for publication.
9. Only after explicit publication approval, create the public remote, push
   `main` and the tag, enable secret scanning, push protection, Issues, and
   private vulnerability reporting, and wait for CI to pass.
10. Create a draft GitHub release from the exact tag:

    ```sh
    gh release create v0.6.0 \
      Poor-Mans-Text-0.6.0.dmg \
      Poor-Mans-Text-0.6.0.dmg.sha256 \
      --verify-tag \
      --draft \
      --title "Poor Man's Text 0.6.0" \
      --notes-file docs/releases/0.6.0.md
    ```

Download the draft assets again, verify the checksum, and only then publish the
draft. No unsigned, ad-hoc-signed, or merely Developer-ID-signed build may be
uploaded as the release application.
