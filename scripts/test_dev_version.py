import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("dev-version.sh").resolve()


class DevVersionTests(unittest.TestCase):
    def test_version_from_real_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = os.environ | {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}

            def git(*args):
                return subprocess.check_output([
                    "git", "-C", directory, "-c", "user.name=Version test",
                    "-c", "user.email=version@example.invalid", "-c", "commit.gpgsign=false",
                    "-c", "core.hooksPath=/dev/null", *args], env=env, text=True).strip()

            def version():
                return subprocess.check_output(["sh", str(SCRIPT)], cwd=root, env=env, text=True).strip()

            git("init", "-q")
            tracked = root / "source"
            tracked.write_text("initial")
            git("add", "source")
            git("commit", "-qm", "Initial")
            commit = git("rev-parse", "--short=7", "HEAD")
            self.assertEqual(version(), f"0.0.0-dev.{commit}")
            git("tag", "v0.2.0")
            self.assertEqual(version(), f"0.2.0-dev.{commit}")
            (root / "untracked").write_text("ignored")
            self.assertEqual(version(), f"0.2.0-dev.{commit}")
            tracked.write_text("changed")
            self.assertEqual(version(), f"0.2.0-dev.{commit}.dirty")
            git("add", "source")
            self.assertEqual(version(), f"0.2.0-dev.{commit}.dirty")
            git("commit", "-qm", "Update")
            self.assertEqual(version(), f"0.2.0-dev.{git('rev-parse', '--short=7', 'HEAD')}")


if __name__ == "__main__":
    unittest.main()
