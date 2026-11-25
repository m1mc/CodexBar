class Codexbar < Formula
  desc "Multi-provider AI quota and usage monitor for Antigravity, Codex, Claude and more"
  homepage "https://github.com/m1mc/CodexBar"
  version "2.2.2"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-macos-arm64.tar.gz"
      sha256 "e341a9f36f888c2c2a685a1d34ba047048fe61ef9bc0b5e530618d492d6aeba1"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-macos-x86_64.tar.gz"
      sha256 "0dfc8e98c6fb7fbff5dfa56e1c48fc1f8dcede9766f6b17fe485293cb9564a39"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-linux-x86_64.tar.gz"
      sha256 "499c2de84e030194bc887fd5d8c458a02889e3ac09dc629bf0d51bbef350df4f"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-v#{version}-linux-aarch64.tar.gz"
      sha256 "4a80f8ee43fcaeae5b971a5217bbdd191f747d7196e0c9379074e514359913b6"
    end
  end

  def install
    libexec.install Dir["*"]
    (libexec/"VERSION").write "#{version}\n"
    bin.install_symlink libexec/"CodexBarCLI" => "codexbar"
  end

  test do
    assert_match(/codexbar/i, shell_output("#{bin}/codexbar --version"))
  end
end
