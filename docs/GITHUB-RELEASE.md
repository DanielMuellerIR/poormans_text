# GitHub release procedure

Release artifacts are built locally from one Git tag. The macOS app and DMG
are signed and notarized locally. Linux packages are built on a Linux x86-64 host.

## Repository metadata

Suggested description:

> Convert documents to Markdown and extract invoice and delivery note fields to JSON. Local OCR, desktop apps and CLI for macOS and Linux.

Suggested topics:

`macos`, `swift`, `markdown`, `rtf`, `rtfd`, `docx`, `odt`, `ods`, `xlsx`,
`xls`, `pdf`, `ocr`, `pandoc`, `document-conversion`

## Release checklist

All steps below use the product version as a single variable. Derive it from
`ProductInfo.swift`, the one source of truth, instead of typing a literal
version anywhere:

```sh
VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' \
  Sources/PoorMansTextCore/ProductInfo.swift)"
```

1. Keep the product version aligned in `ProductInfo.swift`, `App/Info.plist`,
   both READMEs and the changelog. Increase `CFBundleVersion` and update its
   explicit expectation in `Tests/PoorMansTextCoreTests/ProductInfoTests.swift`;
   run `swift test --filter ProductInfoTests` after changing version metadata.
   Confirm that public contact and legal-notice requirements have been resolved
   for the intended form of publication. Never commit a private address merely
   to satisfy this checklist.
2. Confirm that the author name, email address, and full Git history are intended
   to be public. Rewriting history requires a separate, explicit decision.
3. Run `swift test` and `./build.sh release` from a clean checkout.
4. Commit the intended release state and create the annotated `v$VERSION` tag.
5. Run `./install.sh --with-dmg`. One run builds, signs, and notarizes the app,
   packs and notarizes the DMG, writes its checksum, and installs the app and
   the CLI link — all from the same signed bundle. Do not split this into
   `./release.sh` plus `./install.sh`: two runs build and sign twice, so the
   repository app, the installed app, and the app inside the DMG no longer share
   a CodeDirectory hash and step 6 fails.
6. Run `scripts/verify_release.sh "$VERSION"`. It requires the clean, exact release
   tag and independently checks the repository app, the installed app, the DMG,
   the checksum, and the CLI link — including that all three app copies carry
   the same CodeDirectory hash.
7. Perform the public privacy and secret scan over the exact outgoing commit and
   the complete history intended for publication.
8. Only after explicit publication approval, create the public remote, push
   `main` and the tag, enable secret scanning, push protection, Issues, and
   private vulnerability reporting, and wait for CI to pass.
9. Build the Linux packages at the same tag with `./release-linux.sh --format all`.
   Verify the package inventory and checksums. Create a draft GitHub release
   from the tag and attach the macOS and Linux downloads:

    ```sh
    gh release create "v$VERSION" \
      "Poor-Mans-Text-$VERSION.dmg" \
      "Poor-Mans-Text-$VERSION.dmg.sha256" \
      "$LINUX_RELEASE_DIRECTORY"/* \
      --verify-tag \
      --draft \
      --title "Poor Man's Text $VERSION" \
      --notes-file "docs/releases/$VERSION.md"
    ```

Use a Linux release directory containing the four packages and their four checksum
files. Download the draft assets again and verify all five checksums before publishing. No unsigned, ad-hoc-signed, or merely Developer-ID-signed build may be
uploaded as the release application.

10. Publishing the release starts `.github/workflows/publish-appcast.yml`, which
    signs the Sparkle appcast and deploys it to GitHub Pages. Check the workflow
    and fetch the feed afterwards; an older installed build must find, install,
    and restart into the new version. The release notes of this exact release are
    what Sparkle shows in its update dialog. The German
    [SPARKLE-RELEASE.md](SPARKLE-RELEASE.md) describes the one-time setup, the
    key handling, and this step in detail.

If GitHub cannot assign an Arm64 runner, dispatch CI manually from `main`
with the exact release tag as `source-ref` and `macos-26-intel` as `runner`.
To recheck the exact tag with both jobs after a CI configuration fix,
dispatch CI from `main` with the tag as `source-ref` and `macos-26` as the runner.
For an appcast job blocked by runner availability, start a fresh manual
appcast run from `main` with the published `tag` and the Intel runner.
