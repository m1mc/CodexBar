class Codexbar < Formula
  desc "Multi-provider AI quota and usage monitor for Antigravity, Codex, Claude and more"
  homepage "https://github.com/m1mc/CodexBar"
  version "2.2.2"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-arm64.tar.gz"
      sha256 "32326fb1d4edc658990084c3975280d74583d3167c40d5a30415e0194948b80b"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-x86_64.tar.gz"
      sha256 "b5164a454ee7ddc04fbb65af7dec1e8684de3c4174f81002b4c1034e5bd14592"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-linux-x86_64.tar.gz"
      sha256 "6d41cf9c1b7b9b940940381c4a9515b7d805a9e8e8ed9221400d2458f7a2cb47"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-linux-aarch64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  def install
    libexec.install "CodexBarCLI"
    (libexec/"VERSION").write "#{version}\n"
    bin.install_symlink libexec/"CodexBarCLI" => "codexbar"
  end

  test do
    assert_match(/codexbar/i, shell_output("#{bin}/codexbar --version"))
  end
end
