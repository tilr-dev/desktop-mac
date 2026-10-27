"""Contract of .github/workflows/release.yml: each key only in the job that uses it."""
from pathlib import Path
import re
import unittest

WORKFLOW = Path(__file__).resolve().parent.parent / ".github/workflows/release.yml"
APPLE = ("APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_API_KEY_P8_BASE64")
PUBLISHING = ("SPARKLE_PRIVATE_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")


def jobs(text):
    """Job name -> its text; jobs are the two-space keys under `jobs:`."""
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"^  ([a-z-]+):\n", body, flags=re.M)
    return dict(zip(parts[1::2], parts[2::2]))


def steps(job):
    return re.split(r"^      - ", job, flags=re.M)[1:]


def index(job, marker):
    found = [i for i, step in enumerate(steps(job)) if marker in step]
    if not found:
        raise AssertionError(f"No step with {marker!r}")
    return found[0]


class ReleaseWorkflowContract(unittest.TestCase):
    def setUp(self):
        self.text = WORKFLOW.read_text()
        self.jobs = jobs(self.text)

    def test_three_jobs_run_only_by_hand(self):
        self.assertEqual(list(self.jobs), ["server", "app", "publish"])
        triggers = self.text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(re.findall(r"^  ([a-z_]+):", triggers, flags=re.M), ["workflow_dispatch"])

    def test_signing_jobs_hold_no_publication_keys(self):
        for name in ("server", "app"):
            for secret in PUBLISHING:
                self.assertNotIn(secret, self.jobs[name], f"{secret} in {name}")
            self.assertIn("environment: apple-signing", self.jobs[name])

    def test_publication_waits_for_approval_and_holds_no_apple_keys(self):
        publish = self.jobs["publish"]
        self.assertIn("environment: release", publish)
        self.assertIn("needs: [server, app]", publish)
        for secret in APPLE:
            self.assertNotIn(secret, publish)
        self.assertNotIn("ci-apple-keychain.sh import", publish)

    def test_keys_arrive_after_compilation_and_always_leave(self):
        for name, compile_step in (("server", "Compile the server"), ("app", "name: Compile")):
            job = self.jobs[name]
            imported = index(job, "ci-apple-keychain.sh import")
            self.assertLess(index(job, compile_step), imported)
            cleanup = steps(job)[index(job, "ci-apple-keychain.sh cleanup")]
            self.assertIn("if: always()", cleanup)
            self.assertLess(imported, index(job, "ci-apple-keychain.sh cleanup"))
        publish = self.jobs["publish"]
        self.assertIn("if: always()", steps(publish)[index(publish, 'rm -f "$RUNNER_TEMP/sparkle.key"')])

    def test_a_published_server_is_downloaded_not_rebuilt(self):
        server = self.jobs["server"]
        self.assertLess(index(server, "scripts/fetch_server.py"), index(server, "Compile the server"))
        for marker in ("Compile the server", "ci-apple-keychain.sh import", "scripts/release_server.py"):
            self.assertIn("if: steps.fetch.outputs.build == 'true'", steps(server)[index(server, marker)])

    def test_publication_reuses_the_tested_artifacts(self):
        publish = self.jobs["publish"]
        self.assertIn("release_server.py --version \"$version\" --build \"$build\" --publish-only", publish)
        self.assertIn("--publish-only", steps(publish)[index(publish, "scripts/release_all.py")])
        self.assertNotIn("swift build", publish)
        self.assertNotIn("cargo", publish)
        self.assertNotIn("wrangler", self.text)

    def test_resolved_number_flows_to_packaging_and_publication(self):
        build_input = self.text.split('      build:', 1)[1].split('      channel:', 1)[0]
        self.assertIn('required: false', build_input)
        app = self.jobs["app"]
        self.assertIn("build: ${{ steps.number.outputs.build }}", app)
        self.assertLess(index(app, "scripts/ci_release.py build"), index(app, "name: Compile"))
        self.assertEqual(app.count("BUILD: ${{ inputs.build }}"), 1)
        self.assertEqual(app.count("BUILD: ${{ steps.number.outputs.build }}"), 2)
        publish = self.jobs["publish"]
        self.assertNotIn("inputs.build", publish)
        self.assertEqual(publish.count("BUILD: ${{ needs.app.outputs.build }}"), 2)
        self.assertLess(index(publish, "scripts/release_all.py"), index(publish, "scripts/ci_release.py github"))
        self.assertIn("NOTES: ${{ inputs.notes }}", steps(publish)[index(publish, "scripts/ci_release.py github")])
        self.assertEqual(self.text.count("contents: write"), 1)
        self.assertIn("permissions:\n      contents: write", publish)
        self.assertIn("GH_TOKEN: ${{ github.token }}", publish)

    def test_no_caches_and_pinned_actions(self):
        self.assertNotIn("actions/cache", self.text)
        for action in re.findall(r"uses: (\S+)", self.text):
            self.assertRegex(action, r"@[0-9a-f]{40}$")

    def test_inputs_reach_commands_only_through_the_environment(self):
        for job in self.jobs.values():
            for step in steps(job):
                run = step.split("run:", 1)[1] if "run:" in step else ""
                self.assertNotIn("${{", run)


if __name__ == "__main__":
    unittest.main()
