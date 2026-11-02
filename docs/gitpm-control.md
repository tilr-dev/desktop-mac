# Embedded gitpm over Control

Send newline-delimited JSON to the running instance's Unix control socket:

```json
{"id":1,"cmd":"gitpm","command":"link","args":{"package":"/absolute/path/to/plugin"}}
{"id":1,"ok":true,"result":{"id":"…","dist":{"deployed":[],"removed":[],"unmanaged":[],"skipped":[]}}}
```

The result is the pinned Swift FFI record (including all its fields), array,
string, or JSON null for a void operation. Record fields use Swift camelCase.
Enums encode as objects with a `type` equal to the Swift case name and named
associated fields, for example `{"type":"ref","reference":"v1.0.0"}`.
Optional record fields are null. The example above abbreviates the result.

Failures return `ok:false` and `error:{code,kind,message,lostWork,plugins,id?}`.
`code` and `kind` are the stable gitpm snake_case error identifier, such as
`locked`, `not_installed` or `invalid_argument`; they are not a process exit
status (no CLI process is launched). Uninstall confirmations use the `lostWork`
objects unchanged as `confirmed`. Do not automatically confirm discarded work.
Unknown commands, unknown fields and incorrect argument types fail with
`invalid_argument`. Git preflight reports `git` with installation guidance.
The request ID is echoed on success and failure. Other Control errors retain
the existing string error format.

Every workspace operation is bound to the application's configured
plugin-manager workspace (default `<configDir>/plugins`). `root` cannot override it. Free author operations take an explicit `directory`
for their source repository; this does not select a different plugin workspace. Catalog `location` defaults to the configured
catalog; an absent catalog requires an explicit location. Commands share the
app's service queue, including launch-time dist migration and free FFI calls.
There is no CLI download and no page bridge. Host/app selection follows the
normal Control validation and does not change this instance-wide workspace.

`args` is an object, defaulting to `{}`. Required fields are unmarked below;
`?` denotes optional fields. Optional booleans default to false unless noted.
Command names use the FFI Swift spelling; CLI group/flag combinations map to
separate operations (for example `updateAllPlan` or `catalogRegister`).

| Command | Arguments |
| --- | --- |
| `open`, `root`, `list`, `readState`, `check` | none |
| `listView` | `provides?` (the free FFI `list`; returns a full ListView) |
| `browseCatalog`, `catalogLinks` | `location?` |
| `catalogRelease` | `id`, `version?`, `location?` |
| `install` | `source`, `target?`, `reference?`, `package?`, `force?` |
| `download` | `source`, `target?`, `reference?`, `package?` |
| `installFromCatalog` | `id`, `version?`, `force?` |
| `downloadFromCatalog` | `id`, `version?` |
| `link` | `package` (local package directory) |
| `update` | `id`, `target?`, `reference?`, `detach?` |
| `updateAll`, `updateAllPlan` | none |
| `rollback`, `restore`, `uninstallPlan`, `uninstallRefusal` | `id`; refusal evaluates the current uninstall plan |
| `enable`, `disable`, `forget` | `id`, `force?` |
| `uninstall` | `id`, `confirmed?` (array of lost-work objects, default `[]`), `force?` |
| `replace`, `replacePlan`, `replaceCheck`, `replaceResolve` | `original`, `replacement` |
| `syncDist`, `syncDistPlan` | none |
| `fork` | `id`, `destination` |
| `forkPackages` | `ids` (string array), `destination` |
| `forkSource` | `source`, `ids` (string array), `destination`, `reference?`, `customSsh?` |
| `authCheck` | `source`, `customSsh?` |
| `init` | `directory`, `name`, `multi?`, `release?` (default true) |
| `commit` | `directory`, `version`, `package?` |
| `setRemote` | `directory`, `url` |
| `repositoryPackages` | `directory` |
| `editDependency` | `id`, `edit` |
| `editRepositoryDependency` | `directory`, `package`, `edit` (free FFI dependency edit) |
| `catalogUpdate` | `sourcesFile`, `location?`, `customSsh?` |
| `catalogRegister` | `source`, `reference`, `package?`, `build?`, `location?`, `customSsh?` |
| `describeLostWork` | `item` (a lost-work object) |

`target` is a string: `release` (default), `dev` or `ref` (requires `reference`).
Update also accepts `recorded` to follow the recorded mode.
`build` is null or `{url,sha256}`. `edit` is one of:

```json
{"type":"add","dependency":"package-id","requirement":"^1.0"}
{"type":"update","dependency":"old-id","newDependency":"new-id","requirement":"^2.0"}
{"type":"remove","dependency":"package-id"}
```

The original `{"cmd":"plugin-manager"}` request still reports read-only status
without opening or creating the workspace. `gitpm list` opens the manager;
`readState`, `listView` and `check` use read-only free functions.

Run the socket integration test in a logged-in macOS session with
`python3 scripts/test_gitpm_control.py`. It stages a separate signed app and
checks reads, mutations, structured errors and persistence across restarts.
