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
4. Commit the intended release state and create the annotated `v0.5.1` tag.
5. Run the normal notarized installer. It creates and verifies the app, DMG, and
   checksum before installing anything globally.
6. Run `scripts/verify_release.sh 0.5.1`. It requires the clean, exact release
   tag and independently checks both notarized artifacts and their versions.
7. Perform the public privacy and secret scan over the exact outgoing commit and
   the complete history intended for publication.
8. Only after explicit publication approval, create the public remote, push
   `main` and the tag, enable secret scanning, push protection, Issues, and
   private vulnerability reporting, and wait for CI to pass.
9. Create a draft GitHub release from the exact tag:

   ```sh
   gh release create v0.5.1 \
     Poor-Mans-Text-0.5.1.dmg \
     Poor-Mans-Text-0.5.1.dmg.sha256 \
     --verify-tag \
     --draft \
     --title "Poor Man's Text 0.5.1" \
     --notes-file docs/releases/0.5.1.md
   ```

Download the draft assets again, verify the checksum, and only then publish the
draft. No unsigned, ad-hoc-signed, or merely Developer-ID-signed build may be
uploaded as the release application.
