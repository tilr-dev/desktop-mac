"""Contract of .github/workflows/release.yml (release branches and stable tags, each key only in the job that uses it)
and of ci.yml (parallel jobs, the aggregate mac check, Intel only outside pull requests)."""
from pathlib import Path
import re
import itertools
import json
import os
import subprocess
import sys
import textwrap
import unittest

WORKFLOW = Path(__file__).resolve().parent.parent / ".github/workflows/release.yml"
CI = WORKFLOW.with_name("ci.yml")
SETUP = WORKFLOW.parents[1] / "actions/mac-setup/action.yml"
APPLE = ("APPLE_CERTIFICATE_P12_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_API_KEY_P8_BASE64")
PUBLISHING = ("SPARKLE_PRIVATE_KEY", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY")


def jobs(text):
    """Job name -> its text; jobs are the two-space keys under `jobs:`."""
    body = text.split("\njobs:\n", 1)[1]
    parts = re.split(r"^  ([a-z0-9_-]+):\n", body, flags=re.M)
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

    def test_only_release_branch_and_stable_tag_pushes_start_release(self):
        self.assertEqual(list(self.jobs), ["release", "app", "publish"])
        triggers = self.text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(re.findall(r"^  ([a-z_]+):", triggers, flags=re.M), ["push"])
        self.assertIn("branches: ['release/**']", triggers)
        self.assertIn("tags: ['v*', '!v*-rc.*']", triggers)
        self.assertNotIn('workflow_dispatch', self.text)
        self.assertNotIn('inputs.', self.text)
        self.assertIn('group: release\n  cancel-in-progress: false', self.text)
        self.assertNotIn('queue:', self.text)

    def test_shared_workflow_is_pinned_and_has_only_its_app_secret(self):
        release = self.jobs['release']
        pin = re.search(r'release-branch.yml@([0-9a-f]{40})', release)[1]
        self.assertIn('workflow-sha: ' + pin, release)
        self.assertIn('app-client-id: ${{ vars.TILR_BOT_CLIENT_ID }}', release)
        self.assertIn('app-private-key: ${{ secrets.TILR_BOT_PRIVATE_KEY }}', release)
        self.assertNotIn('environment:', release)
        self.assertNotIn('secrets: inherit', release)
        for secret in APPLE + PUBLISHING:
            self.assertNotIn(secret, release)
        root = WORKFLOW.parents[2]
        self.assertEqual(pin, 'c31b80fcfd5cb9398a193d422c212326302d0c44')
        self.assertNotIn('package-path:', release)
        self.assertNotIn('release_created', self.text)
        for filename in ('release-please-config.json', '.release-please-manifest.json', 'version.txt'):
            self.assertFalse((root / filename).exists())

    def test_shared_release_outputs_gate_channel_and_tag_checkout(self):
        app = self.jobs['app']
        condition = app.split('if: ', 1)[1].splitlines()[0]
        # Evaluate the actual workflow gate, including missing/partial outputs.
        expression = condition.replace('needs.release.outputs.', '').replace('github.ref_type', 'ref_type')
        expression = expression.replace('||', 'or').replace('&&', 'and')
        for tag, version, is_rc, ref_type in itertools.product(
                ('', 'v0.3.0'), ('', '0.3.0'), ('', 'true', 'false'), ('branch', 'tag')):
            with self.subTest(tag=tag, version=version, is_rc=is_rc, ref_type=ref_type):
                expected = bool(tag and version and (is_rc == 'true' or
                                (is_rc == 'false' and ref_type == 'tag')))
                self.assertEqual(bool(eval(expression, {}, dict(tag=tag, version=version,
                                                               is_rc=is_rc, ref_type=ref_type))), expected)
        self.assertIn('needs: [release, app]', self.jobs['publish'])
        for name in ('app', 'publish'):
            checkout = steps(self.jobs[name])[0]
            self.assertIn('ref: ${{ needs.release.outputs.tag }}', checkout)
            self.assertIn('persist-credentials: false', checkout)
        packaging = steps(app)[index(app, 'scripts/release_all.py')]
        self.assertIn('CHANNEL: ${{ steps.metadata.outputs.channel }}', packaging)
        self.assertIn('RELEASE_TAG: ${{ steps.metadata.outputs.release_tag }}', packaging)
        self.assertIn('--release-tag "$RELEASE_TAG"', packaging)
        self.assertIn('--channel "$CHANNEL"', packaging)
        publication = steps(self.jobs['publish'])[index(self.jobs['publish'], 'ci_release.py publish')]
        self.assertIn('TAG: ${{ needs.release.outputs.tag }}', publication)
        self.assertNotIn('scripts/release_all.py', publication)

    def test_release_is_verified_before_signing_and_cdn_keys(self):
        app, publish = self.jobs['app'], self.jobs['publish']
        self.assertLess(index(app, 'ci_release.py release'), index(app, 'ci-apple-keychain.sh import'))
        self.assertLess(index(publish, 'ci_release.py release'), index(publish, 'name: Write the Sparkle key'))
        for job in (app, publish):
            step = steps(job)[index(job, 'ci_release.py release')]
            self.assertIn('TAG: ${{ needs.release.outputs.tag }}', step)
            self.assertIn('GH_TOKEN: ${{ github.token }}', step)
        self.assertIn('version: ${{ steps.metadata.outputs.version }}', app)
        self.assertEqual(app.count('VERSION: ${{ steps.metadata.outputs.version }}'), 2)
        self.assertIn('VERSION: ${{ needs.app.outputs.version }}', publish)

    def test_signing_jobs_hold_no_publication_keys(self):
        for name in ("app",):
            for secret in PUBLISHING:
                self.assertNotIn(secret, self.jobs[name], f"{secret} in {name}")
            self.assertIn("environment: apple-signing", self.jobs[name])

    def test_publication_uses_restricted_environment_and_holds_no_apple_keys(self):
        publish = self.jobs["publish"]
        self.assertIn("environment: release", publish)
        self.assertIn("needs: [release, app]", publish)
        for secret in APPLE:
            self.assertNotIn(secret, publish)
        self.assertNotIn("ci-apple-keychain.sh import", publish)

    def test_keys_arrive_after_compilation_and_always_leave(self):
        for name, compile_step in (("app", "name: Compile"),):
            job = self.jobs[name]
            imported = index(job, "ci-apple-keychain.sh import")
            self.assertLess(index(job, compile_step), imported)
            cleanup = steps(job)[index(job, "ci-apple-keychain.sh cleanup")]
            self.assertIn("if: always()", cleanup)
            self.assertLess(imported, index(job, "ci-apple-keychain.sh cleanup"))
        publish = self.jobs["publish"]
        self.assertIn("if: always()", steps(publish)[index(publish, 'rm -f "$RUNNER_TEMP/sparkle.key"')])

    def test_pr_ci_checks_no_server_pin(self):
        ci = WORKFLOW.with_name('ci.yml').read_text()
        self.assertIn("pull_request:", ci)
        self.assertNotIn('scripts/fetch_server.py', ci)
        self.assertFalse((WORKFLOW.parents[2] / 'server-release.json').exists())

    def test_server_is_imported_before_apple_keys_arrive(self):
        app = self.jobs["app"]
        self.assertLess(index(app, "scripts/fetch_server.py"), index(app, "ci-apple-keychain.sh import"))
        self.assertNotIn("--public-key", steps(app)[index(app, "scripts/fetch_server.py")])
        self.assertNotIn("--min-app-build", self.text)
        self.assertNotIn('server_min_app_build', self.text)
        for forbidden in ("tilrd-src", "Compile the server", "scripts/release_server.py", "notarytool"):
            self.assertNotIn(forbidden, app)
        self.assertNotIn('name: server', self.text)

    def test_plugin_manager_is_the_pinned_gitpm_release_not_compiled(self):
        ci = jobs(CI.read_text())
        setup = SETUP.read_text()
        app = self.jobs["app"]
        for text in (*ci.values(), setup, app):
            for forbidden in ("tilr-dev/gitpm", "GITPM_DIR", "rustup", "cargo", "build-gitpm.sh"):
                self.assertNotIn(forbidden, text)
        self.assertIn("python3 scripts/fetch_gitpm.py", setup)
        for name in ("probe", "native-plugins", "x86_64"):
            self.assertLess(index(ci[name], "./.github/actions/mac-setup"), index(ci[name], "name: "))
            self.assertNotIn("gitpm: 'false'", ci[name])
        compile_step = steps(app)[index(app, "name: Compile")]
        self.assertLess(compile_step.index("scripts/fetch_gitpm.py"), compile_step.index("swift package resolve"))

    def test_publication_reuses_the_tested_artifacts(self):
        publish = self.jobs["publish"]
        self.assertNotIn("scripts/release_server.py", publish)
        self.assertIn("ci_release.py publish", publish)
        self.assertNotIn("swift build", publish)
        self.assertNotIn("cargo", publish)
        self.assertNotIn("wrangler", self.text)

    def test_resolved_number_and_shared_tag_flow_to_publication(self):
        app = self.jobs['app']
        self.assertIn('build: ${{ steps.number.outputs.build }}', app)
        self.assertLess(index(app, 'scripts/ci_release.py build'), index(app, 'name: Compile'))
        self.assertEqual(app.count('BUILD: ${{ steps.number.outputs.build }}'), 2)
        publish = self.jobs['publish']
        self.assertEqual(publish.count('BUILD: ${{ needs.app.outputs.build }}'), 2)
        self.assertLess(index(publish, 'scripts/ci_release.py publish'), index(publish, 'scripts/ci_release.py github'))
        github = steps(publish)[index(publish, 'scripts/ci_release.py github')]
        self.assertIn('TAG: ${{ needs.release.outputs.tag }}', github)
        self.assertIn('--tag "$TAG"', github)
        self.assertIn('--notes-file "$RUNNER_TEMP/notes.txt"', publish)
        self.assertEqual(self.text.count('contents: write'), 1)
        self.assertIn('permissions:\n      contents: write', publish)
        self.assertIn('GH_TOKEN: ${{ github.token }}', publish)

    def test_no_caches_and_pinned_actions(self):
        self.assertNotIn("actions/cache", self.text)
        for action in re.findall(r"uses: (\S+)", self.text):
            self.assertRegex(action, r"@[0-9a-f]{40}$")

    def test_inputs_reach_commands_only_through_the_environment(self):
        for job in self.jobs.values():
            for step in steps(job):
                run = step.split("run:", 1)[1] if "run:" in step else ""
                self.assertNotIn("${{", run)


class CiWorkflowContract(unittest.TestCase):
    def setUp(self):
        self.text = CI.read_text()
        self.jobs = jobs(self.text)

    def aggregate(self, event, results):
        """Runs the check of the aggregate mac job on the given need results; True when it passes."""
        run = steps(self.jobs["mac"])[0].split("run: |\n", 1)[1]
        script = textwrap.dedent(run).split("<<'EOF'\n", 1)[1].split("\nEOF\n", 1)[0]
        needs = {job: {"result": result, "outputs": {}} for job, result in results.items()}
        env = {**os.environ, "NEEDS": json.dumps(needs), "EVENT": event}
        return subprocess.run([sys.executable, "-c", script], env=env, capture_output=True).returncode == 0

    def test_no_push_to_main_and_a_nightly_full_run(self):
        triggers = self.text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(re.findall(r"^  ([a-z_]+):", triggers, flags=re.M),
                         ["merge_group", "pull_request", "push", "schedule", "workflow_dispatch"])
        self.assertIn("pull_request:\n    branches: [main, 'release/**']", triggers)
        self.assertIn("push:\n    branches: ['release/**']", triggers)
        self.assertRegex(triggers, r"schedule:\n    - cron: '[0-9 *]+'")

    def test_jobs_run_in_parallel_under_the_aggregate_mac(self):
        checks = ["probe", "release-tests", "native-plugins", "app-tests", "x86_64"]
        self.assertEqual(list(self.jobs), checks + ["mac"])
        for name in checks:
            self.assertNotIn("needs:", self.jobs[name])
            self.assertIn("uses: ./.github/actions/mac-setup", self.jobs[name])
        mac = self.jobs["mac"]
        self.assertIn("if: always()", mac)
        self.assertIn(f"needs: [{', '.join(checks)}]", mac)
        self.assertIn("NEEDS: ${{ toJSON(needs) }}", mac)

    def test_intel_builds_on_every_event_but_pull_requests(self):
        x86 = self.jobs["x86_64"]
        self.assertIn("    if: github.event_name != 'pull_request'\n", x86)
        self.assertIn("swift build -c release --arch x86_64", x86)
        self.assertNotIn("--arch x86_64", "".join(job for name, job in self.jobs.items() if name != "x86_64"))
        for name in ("probe", "release-tests", "native-plugins", "app-tests"):
            self.assertNotRegex(self.jobs[name], r"^    if:", name)

    def test_mac_fails_unless_every_job_succeeded(self):
        passed = dict.fromkeys(["probe", "release-tests", "native-plugins", "app-tests", "x86_64"], "success")
        for event in ("pull_request", "merge_group", "push", "schedule", "workflow_dispatch"):
            self.assertTrue(self.aggregate(event, passed), event)
            for job in passed:
                for result in ("failure", "cancelled"):
                    self.assertFalse(self.aggregate(event, {**passed, job: result}), (event, job, result))
            for job in ("probe", "release-tests", "native-plugins", "app-tests"):
                self.assertFalse(self.aggregate(event, {**passed, job: "skipped"}), (event, job))
        self.assertTrue(self.aggregate("pull_request", {**passed, "x86_64": "skipped"}))
        for event in ("merge_group", "push", "schedule", "workflow_dispatch"):
            self.assertFalse(self.aggregate(event, {**passed, "x86_64": "skipped"}), event)

    def test_build_cache_is_keyed_by_job_toolchain_and_resolved_packages(self):
        setup = SETUP.read_text()
        self.assertIn("path: ~/Library/Caches/org.swift.swiftpm", setup)
        self.assertIn("path: ${{ inputs.build-paths }}", setup)
        key = re.search(r"\n        key: (build-.*)\n", setup).group(1)
        for part in ("inputs.job", "runner.os", "runner.arch", "steps.toolchain.outputs.swift", "hashFiles('Package.resolved'"):
            self.assertIn(part, key)
        self.assertIn("swift --version 2>&1 | shasum", setup)
        for action in re.findall(r"uses: (\S+)", self.text + setup):
            if not action.startswith("./"):
                self.assertRegex(action, r"@[0-9a-f]{40}$")
        names = re.findall(r"^          job: (\S+)$", self.text, flags=re.M)
        self.assertEqual(names, ["probe", "release-tests", "native-plugins", "app-tests", "x86_64"])


if __name__ == "__main__":
    unittest.main()
