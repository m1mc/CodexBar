class Codexbar < Formula
  desc "Multi-provider AI quota and usage monitor for Antigravity, Codex, Claude and more"
  homepage "https://github.com/m1mc/CodexBar"
  version "2.1.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-arm64.tar.gz"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-x86_64.tar.gz"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-linux-x86_64.tar.gz"
    end
  end

  def install
    bin.install "CodexBarCLI" => "codexbar"
  end

  test do
    assert_match "codexbar", shell_output("#{bin}/codexbar --version")
  end
end
