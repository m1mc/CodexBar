#!/usr/bin/env python3
"""Verify release archives and Homebrew installs retain the CLI version metadata."""

import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ReleaseCLIVersionTests(unittest.TestCase):
    def test_release_archives_include_the_tag_version(self):
        workflow = json.loads(subprocess.check_output([
            "ruby", "-ryaml", "-rjson", "-e",
            'puts JSON.generate(YAML.load_file(ARGV[0])["jobs"])',
            str(ROOT / ".github/workflows/multiplatform-release.yml"),
        ], text=True))
        for job, arches in (("build-macos", [None]), ("build-linux", ["x86_64", "aarch64"])):
            for arch in arches:
                with self.subTest(job=job, arch=arch), tempfile.TemporaryDirectory() as directory:
                    work = Path(directory)
                    binary_dir = work / ".build/release"
                    binary_dir.mkdir(parents=True)
                    binary = binary_dir / "CodexBarCLI"
                    binary.write_text("#!/bin/sh\nexit 0\n")
                    binary.chmod(0o755)
                    tools = work / "tools"
                    tools.mkdir()
                    swift = tools / "swift"
                    swift.write_text(
                        '#!/bin/sh\ncase " $* " in\n'
                        '  *" --show-bin-path "*) printf "%s\\n" "$BINARY_DIR" ;;\nesac\n')
                    swift.chmod(0o755)
                    step = next(step for step in workflow[job]["steps"]
                                if step.get("name", "").startswith("Build CodexBarCLI"))
                    step_run = step["run"].replace("${{ matrix.arch }}", arch or "")
                    step_environment = {
                        key: value.replace("${{ inputs.tag || github.ref_name }}", "v2.2.3")
                        for key, value in step.get("env", {}).items()
                    }
                    subprocess.run(["bash", "-eu", "-c", step_run], cwd=work, check=True,
                                   capture_output=True, text=True, env={
                                       **os.environ, "PATH": f"{tools}:{os.environ['PATH']}",
                                       "BINARY_DIR": str(binary_dir), **step_environment,
                                   })
                    archives = sorted((work / "dist").glob("*.tar.gz"))
                    self.assertEqual(len(archives), 2 if job == "build-macos" else 1)
                    for archive in archives:
                        with self.subTest(archive=archive.name), tarfile.open(archive) as contents:
                            self.assertIn("VERSION", contents.getnames())
                            self.assertEqual(contents.extractfile("VERSION").read(), b"2.2.3\n")
                            self.assertEqual(contents.extractfile("CodexBarCLI").read(), binary.read_bytes())

    def test_formula_keeps_version_next_to_the_resolved_binary(self):
        # Evaluate the real install method with only Homebrew's filesystem DSL replaced.
        harness = r'''
require "pathname"
require "fileutils"
class Destination < Pathname
  def install(source)
    FileUtils.mkdir_p(to_s)
    if source.is_a?(Hash)
      source.each { |from, to| FileUtils.cp(from, join(to)) }
    else
      FileUtils.cp(source, to_s)
    end
  end
  def install_symlink(mapping)
    FileUtils.mkdir_p(to_s)
    mapping.each { |source, name| File.symlink(source, join(name)) }
  end
end
class Formula
  def self.method_missing(*) end
  def self.test(*) end
  def version; "9.8.7" end
  def bin; Destination.new(File.expand_path("prefix/bin")) end
  def libexec; Destination.new(File.expand_path("prefix/libexec")) end
end
load ARGV.fetch(0)
Codexbar.new.install
'''
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            (work / "CodexBarCLI").write_bytes(b"release binary")
            subprocess.run(["ruby", "-e", harness, str(ROOT / "Formula/codexbar.rb")],
                           cwd=work, check=True, capture_output=True, text=True)
            binary = (work / "prefix/bin/codexbar").resolve()
            self.assertEqual(binary.read_bytes(), b"release binary")
            version = binary.with_name("VERSION")
            self.assertTrue(version.is_file(), "Installed CLI cannot determine its version")
            self.assertEqual(version.read_text().strip(), "9.8.7")
            self.assertFalse((work / "prefix/bin/VERSION").exists(),
                             "Generic metadata must not be linked into the shared PATH")


if __name__ == "__main__":
    unittest.main()
