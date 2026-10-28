"""Contract of .github/workflows/release.yml: only from a release branch, each key only in the job that uses it."""
from pathlib import Path
import re
import json
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

    def test_only_pushes_to_release_branches_start_release(self):
        self.assertEqual(list(self.jobs), ["release", "app", "publish"])
        triggers = self.text.split("\non:\n", 1)[1].split("\n\n", 1)[0]
        self.assertEqual(re.findall(r"^  ([a-z_]+):", triggers, flags=re.M), ["push"])
        self.assertIn("branches: ['release/**']", triggers)
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
        config = json.loads((root / 'release-please-config.json').read_text())
        manifest = json.loads((root / '.release-please-manifest.json').read_text())
        self.assertEqual(config['release-type'], 'simple')
        self.assertFalse(config['include-component-in-tag'])
        self.assertEqual(list(config['packages']), ['.'])
        self.assertEqual(manifest['.'], (root / 'version.txt').read_text().strip())

    def test_shared_release_outputs_gate_channel_and_tag_checkout(self):
        app = self.jobs['app']
        condition = app.split('if: ', 1)[1].splitlines()[0]
        self.assertEqual(condition, "needs.release.outputs.is_rc == 'true' || (needs.release.outputs.release_created == 'true' && needs.release.outputs.is_rc == 'false')")
        # Evaluate the actual gate for candidate, stable merge and absent/partial outputs.
        expression = condition.replace('needs.release.outputs.', '').replace('||', 'or').replace('&&', 'and')
        for is_rc, release_created, expected in [('true', 'false', True), ('false', 'true', True),
                                                ('false', 'false', False), ('', '', False), ('', 'true', False)]:
            self.assertEqual(eval(expression, {}, dict(is_rc=is_rc, release_created=release_created)), expected)
        self.assertIn('needs: [release, app]', self.jobs['publish'])
        for name in ('app', 'publish'):
            checkout = steps(self.jobs[name])[0]
            self.assertIn('ref: ${{ needs.release.outputs.tag }}', checkout)
            self.assertIn('persist-credentials: false', checkout)
        packaging = steps(app)[index(app, 'scripts/release_all.py')]
        self.assertIn('CHANNEL: ${{ steps.metadata.outputs.channel }}', packaging)
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

    def test_server_is_imported_before_apple_keys_arrive(self):
        app = self.jobs["app"]
        self.assertLess(index(app, "scripts/fetch_server.py"), index(app, "ci-apple-keychain.sh import"))
        self.assertNotIn("--min-app-build", self.text)
        self.assertNotIn('server_min_app_build', self.text)
        for forbidden in ("tilrd-src", "Compile the server", "scripts/release_server.py", "notarytool"):
            self.assertNotIn(forbidden, app)
        self.assertNotIn('name: server', self.text)

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


if __name__ == "__main__":
    unittest.main()
