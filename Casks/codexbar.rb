cask "codexbar" do
  version "2.2.2"
  sha256 "bae8b0451fdc396e42fe7f6490c79fc91d78b495582a2f3c18571168a37233f2"

  url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBar-macOS.dmg"
  name "CodexBar"
  desc "Menu bar usage monitor for AI coding assistants"
  homepage "https://github.com/m1mc/CodexBar"

  livecheck do
    url "https://api.github.com/repos/m1mc/CodexBar/releases/latest"
    strategy :json do |json|
      json["tag_name"]&.sub(/^v/, "")
    end
  end

  auto_updates true
  depends_on macos: :sonoma

  app "CodexBar.app"
  binary "#{appdir}/CodexBar.app/Contents/Helpers/CodexBarCLI", target: "codexbar"

  zap trash: [
    "~/Library/Application Support/CodexBar",
    "~/Library/Caches/com.steipete.CodexBar",
    "~/Library/Preferences/com.steipete.CodexBar.plist",
  ]
end
