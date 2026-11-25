cask "codexbar" do
  version "2.2.2"
  sha256 "0f5fd57c4d54d5d8ac2d9d09ea5d769e5a4ffe34e1c303fa95c4b0d7424ea45f"

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
