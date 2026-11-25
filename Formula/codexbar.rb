class Codexbar < Formula
  desc "Multi-provider AI quota and usage monitor for Antigravity, Codex, Claude and more"
  homepage "https://github.com/m1mc/CodexBar"
  version "2.2.2"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-arm64.tar.gz"
      sha256 "f27be97570a7f3f0d6d9625457be29c11246c67c911163453c43f5478b80f09a"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-macos-x86_64.tar.gz"
      sha256 "b2287b98399d908ca5eb4db6c2aad96ee0a79db8fc3f8dc1d87dd415967d9de6"
    end
  end

  on_linux do
    if Hardware::CPU.intel?
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-linux-x86_64.tar.gz"
      sha256 "df0c0a41114e2dfe175f14d86a59e9bf22895508e154609361116beb3aa51b09"
    else
      url "https://github.com/m1mc/CodexBar/releases/download/v#{version}/CodexBarCLI-linux-aarch64.tar.gz"
      sha256 "c8badc6c29dd8f19b73bedead4e5f42642d888400860853c5443a17a0c70d172"
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
