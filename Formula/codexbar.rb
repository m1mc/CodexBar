class Codexbar < Formula
  desc "Multi-provider AI quota and usage monitor for Antigravity, Codex, Claude and more"
  homepage "https://github.com/m1mc/CodexBar"
  version "2.2.1"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-arm64.tar.gz"
      sha256 "fae6a4e8cd3d8dd9e278f28395b34f538b37b20d6169e5b93e4ba3ed564f27bb"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-x86_64.tar.gz"
      sha256 "605eb5296baaec49f1e43503fae6244b9f35762fd95f37d78342ce1a5317c900"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-linux-x86_64.tar.gz"
      sha256 "9d418d0d2f5a20a83645119369b36cdf659cc294d847db94cb602402766de56f"
    end
  end

  def install
    bin.install "CodexBarCLI" => "codexbar"
  end

  test do
    assert_match(/codexbar/i, shell_output("#{bin}/codexbar --version"))
  end
end
