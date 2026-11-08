class Codexbar < Formula
  desc "Multi-provider AI quota and usage monitor for Antigravity, Codex, Claude and more"
  homepage "https://github.com/m1mc/CodexBar"
  version "2.1.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-arm64.tar.gz"
      sha256 "e5af76d83f9daa29d775ba51e121db6e58139fa3e113ee61a77301a51912d94a"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-x86_64.tar.gz"
      sha256 "2df541dc914d183645ade259c2889c8565e6074ebdf9cf55a4ab6ee2152c86a1"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-linux-x86_64.tar.gz"
      sha256 "dbe9d90b90b3fa882cb81d1017f1c37610b8a4661e17ae6007d1e9e81e5bb193"
    end
  end

  def install
    bin.install "CodexBarCLI" => "codexbar"
  end

  test do
    assert_match(/codexbar/i, shell_output("#{bin}/codexbar --version"))
  end
end
