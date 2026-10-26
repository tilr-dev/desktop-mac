import argparse
from contextlib import redirect_stdout
import io
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import release_server
import release_server_all as release


class ServerReleaseCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.clone = self.root / "tilrd"
        self.clone.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        proto = self.clone / "crates/tilr-proto/src/lib.rs"
        proto.parent.mkdir(parents=True)
        proto.write_text("pub const PROTOCOL_VERSION: u32 = 1;")
        self.git("add", ".")
        self.git("commit", "-qm", "Tagged server")
        self.git("tag", "v0.1.0")
        self.tag_commit = self.git("rev-parse", "HEAD")
        proto.write_text("pub const PROTOCOL_VERSION: u32 = 99;")
        self.git("commit", "-qam", "Unreleased server")
        self.head = self.git("rev-parse", "HEAD")
        self.args = argparse.Namespace(version="0.1.0", build=7, min_app_build=2,
                                       tag="v0.1.0", tilrd_repo=self.clone,
                                       channel="beta", preview=False)
        scripts = self.root / "scripts"
        scripts.mkdir()
        # Child-process release-tool doubles invoke executable Apple/Wrangler stubs.
        tools = self.root / "tools"
        tools.mkdir()
        stub = '#!' + sys.executable + '\nimport os,sys\nwith open(os.environ["EVENTS"], "a") as f: f.write(sys.argv[0].split("/")[-1]+"\\n")\n'
        for name in ("codesign", "xcrun", "wrangler"):
            path = tools / name
            path.write_text(stub)
            path.chmod(0o755)
        (scripts / "release_all.py").write_text('''import os,sys
assert sys.argv[1:] == ["--check", "--publish"]
with open(os.environ["EVENTS"], "a") as f: f.write("preflight\\n")
if os.environ.get("FAIL_STEP") == "preflight": sys.exit(1)
''')
        (scripts / "release_server.py").write_text('''import json,os,pathlib,subprocess,sys
args = sys.argv[1:]
def value(flag): return args[args.index(flag)+1]
source = pathlib.Path(value("--source"))
assert "= 1;" in (source / "crates/tilr-proto/src/lib.rs").read_text()
assert subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip() == os.environ["TAG_COMMIT"]
step = "publish" if "--publish-only" in args else "build"
with open(os.environ["EVENTS"], "a") as f: f.write(step+"\\n")
if os.environ.get("FAIL_STEP") == step: sys.exit(1)
if step == "publish":
    subprocess.run(["wrangler"], check=True)
    sys.exit(0)
commit = subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=source, text=True).strip()
for arch in ("arm64", "x86_64"):
    subprocess.run(["codesign"], check=True)
    subprocess.run(["xcrun", "notarytool"], check=True)
    path = pathlib.Path(__file__).parents[1] / "build/server-releases" / f"0.1.0-7-{arch}"
    path.mkdir(parents=True)
    manifest = dict(version="0.1.0", build=7, arch=arch, protocolVersion=1, minAppBuild=2, serverVersion=f"0.1.0-build7-{commit}")
    (path / "release.json").write_text(json.dumps(dict(preview=False, manifest=manifest)))
    binary = path / "tilrd"
    binary.write_text("#!" + sys.executable + "\\nprint('tilrd 0.1.0-build7-" + commit + "')\\n")
    binary.chmod(0o755)
''')
        self.events = self.root / "events"
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        EVENTS=str(self.events), TAG_COMMIT=self.tag_commit)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.clone), *args], text=True).strip()

    def execute(self, answer="publish", fail=None):
        output = io.StringIO()
        if fail:
            self.env["FAIL_STEP"] = fail
        def feed_fetch(url, path):
            arch = "arm64" if "/arm64/" in url else "x86_64"
            manifest = json.loads((self.root / f"build/server-releases/0.1.0-7-{arch}/release.json").read_text())["manifest"]
            path.write_text(json.dumps(dict(schema=1, component="tilrd", arch=arch, channel="beta", releases=[dict(manifest=manifest)])))
            with self.events.open("a") as file:
                file.write("feed-" + arch + "\n")
            return True
        with patch.object(release, "release_environment", return_value=self.env) as environment, \
             patch("builtins.input", side_effect=EOFError if answer is None else None, return_value=answer), \
             patch.object(release, "fetch", side_effect=feed_fetch), \
             patch.object(release, "verify_envelope", side_effect=lambda data, _: json.loads(data)), \
             redirect_stdout(output):
            release.execute(self.args, self.root)
            if self.args.preview:
                environment.assert_not_called()
        self.assertEqual(self.git("rev-parse", "HEAD"), self.head)
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        return output.getvalue()

    def test_tagged_release_orders_tools_confirmation_feeds_and_pin(self):
        output = self.execute()
        self.assertEqual(self.events.read_text().splitlines(), ["preflight", "build", "codesign", "xcrun", "codesign", "xcrun", "publish", "wrangler", "feed-arm64", "feed-x86_64"])
        self.assertIn('server-release.json: {"version": "0.1.0", "build": 7, "protocolVersion": 1}', output)
        self.assertIn('"serverVersion": "0.1.0-build7-', output)

    def test_refusal_and_eof_leave_built_artifacts_unpublished(self):
        for answer in ("yes", "", None):
            with self.subTest(answer=answer):
                self.events.write_text("")
                shutil.rmtree(self.root / "build", ignore_errors=True)
                self.execute(answer)
                self.assertNotIn("publish", self.events.read_text())
                self.assertTrue((self.root / "build/server-releases/0.1.0-7-arm64/release.json").exists())

    def test_preview_without_credentials_or_node(self):
        self.args.preview = True
        with patch.dict(os.environ, {}, clear=True):
            output = self.execute()
        self.assertIn("Planned:", output)
        self.assertIn('"protocolVersion": 1', output)
        self.assertFalse(self.events.exists())

    def test_failure_stops_later_steps_and_cleans_worktree(self):
        for step in ("preflight", "build", "publish"):
            with self.subTest(step=step):
                self.events.write_text("")
                with self.assertRaises(subprocess.CalledProcessError):
                    self.execute(fail=step)
                events = self.events.read_text().splitlines()
                self.assertNotIn("feed-arm64", events)
                if step == "preflight":
                    self.assertNotIn("build", events)
                self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)

    def test_branch_name_cannot_replace_tag(self):
        self.args.tag = self.git("branch", "--show-current")
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute()
        self.assertFalse(self.events.exists())

    def test_revision_expression_cannot_replace_exact_tag(self):
        self.git("tag", "newer")
        self.args.tag = "newer~1"
        with self.assertRaises(subprocess.CalledProcessError):
            self.execute()
        self.assertFalse(self.events.exists())

    def test_invalid_protocol_stops_before_preflight(self):
        proto = self.clone / "crates/tilr-proto/src/lib.rs"
        proto.write_text("pub const PROTOCOL_VERSION: u32 = 0;")
        self.git("commit", "-qam", "Invalid protocol")
        self.git("tag", "invalid")
        self.args.tag = "invalid"
        with self.assertRaisesRegex(ValueError, "PROTOCOL_VERSION"):
            self.execute()
        self.assertFalse(self.events.exists())

    def test_node_must_be_at_least_22(self):
        with patch.object(release.subprocess, "check_output", return_value="v18.0.0"):
            with self.assertRaisesRegex(ValueError, "Node >=22"):
                release.release_environment()
        with patch.object(release.subprocess, "check_output", return_value="v22.1.0"):
            self.assertTrue(release.release_environment()["PATH"].startswith("/opt/homebrew/bin:"))

    def test_real_builder_receives_detached_source_and_apple_stubs(self):
        tools = self.root / "tools"
        stub = "#!" + sys.executable + "\n" + r"""
import json,os,pathlib,shutil,sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["EVENTS"], "a") as file: file.write(name+"\n")
if name == "cargo":
    assert "= 1;" in pathlib.Path("crates/tilr-proto/src/lib.rs").read_text()
    target = args[args.index("--target")+1]
    output = pathlib.Path(args[args.index("--target-dir")+1]) / target / "release/tilrd"
    output.parent.mkdir(parents=True)
    output.write_text(os.environ["TILR_BUILD_VERSION"] + "-" + os.environ["TILR_BUILD_COMMIT"])
elif name == "ditto":
    if "-c" in args: pathlib.Path(args[-1]).write_text("archive")
    else: shutil.copyfile(args[0], args[1])
elif name == "xcrun": print(json.dumps(dict(status="Accepted")))
"""
        for name in ("cargo", "ditto", "lipo", "strip", "codesign", "xcrun"):
            path = tools / name
            path.write_text(stub)
            path.chmod(0o755)
        with release.tagged_source(self.clone, self.args.tag) as (source, _), \
             patch.dict(os.environ, self.env):
            for arch in release.TARGETS:
                directory = self.root / ("real-" + arch)
                manifest = release_server.build_release(directory, arch, "0.1.0", 7,
                    dict(TILR_SIGN_IDENTITY="Test Identity", TILR_NOTARY_PROFILE="test"), False,
                    2, None, source=source)
                self.assertEqual(manifest["protocolVersion"], 1)
                self.assertEqual((directory / "tilrd").read_text(), manifest["serverVersion"])
                self.assertFalse(json.loads((directory / "release.json").read_text())["preview"])
        self.assertEqual(self.events.read_text().splitlines().count("cargo"), 2)
        self.assertEqual(self.events.read_text().splitlines().count("xcrun"), 2)

    def test_wrong_feed_fails(self):
        directory = self.root / "artifact"
        directory.mkdir()
        def fetch(_, path):
            path.write_text("{}")
            return True
        with patch.object(release, "fetch", side_effect=fetch), \
             patch.object(release, "verify_envelope", return_value=dict(arch="arm64", releases=[])):
            with self.assertRaisesRegex(ValueError, "does not contain"):
                release.verify_feeds([("arm64", directory, {"build": 7})], "stable")


if __name__ == "__main__":
    unittest.main()
