cask "poor-mans-text" do
  version "0.16.6"
  sha256 "d13f3256a9bb9e22b8e1382ad0d2edbe50933b97d82a2f4612e50fcb674e7c23"

  url "https://github.com/DanielMuellerIR/poormans_text/releases/download/v#{version}/Poor-Mans-Text-#{version}.dmg"
  name "Poor Man's Text"
  desc "Convert documents, spreadsheets, PDFs, and images to Markdown"
  homepage "https://github.com/DanielMuellerIR/poormans_text"

  auto_updates true
  depends_on formula: "pandoc"
  depends_on macos: :ventura

  app "Poor Man's Text.app"
  binary "#{appdir}/Poor Man's Text.app/Contents/Resources/poormans-text"
end
