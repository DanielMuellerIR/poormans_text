# Homebrew Cask draft

`Casks/poor-mans-text.rb` is a reviewable Cask definition for the notarized universal
DMG. It installs the application and links the bundled `poormans-text` CLI;
Pandoc is a dependency. The application requires macOS 13 or later and includes
its own Sparkle updater.

The definition currently targets the published 0.16.6 release. Before submitting
or using a newer release, update both `version` and `sha256` from its verified
DMG. A checksum must never be replaced with `:no_check`.

This file has not been submitted to `homebrew/cask` and no tap has been published.
Homebrew's [acceptance policy](https://docs.brew.sh/Acceptable-Casks) applies to a
future submission; a valid definition does not guarantee acceptance.

For a local review:

```sh
brew style packaging/homebrew/Casks/poor-mans-text.rb
brew tap-new --no-git local/poor-mans-text-review
mkdir -p "$(brew --repository local/poor-mans-text-review)/Casks"
cp packaging/homebrew/Casks/poor-mans-text.rb \
  "$(brew --repository local/poor-mans-text-review)/Casks/"
brew audit --cask --online local/poor-mans-text-review/poor-mans-text
brew untap local/poor-mans-text-review
```

Validation must use the release download, compare its SHA-256, and check the app
name, CLI path, minimum macOS version and both architectures inside the DMG.
Do not install the Cask over a separately managed application merely to validate
its metadata.
