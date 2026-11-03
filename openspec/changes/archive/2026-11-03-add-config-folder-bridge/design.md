## Design
Use a per-tab WKScriptMessageHandlerWithReply, restricted to the owning top-level tilr origin and web view. Requests are { op: read | write, name, text? }; read replies with UTF-8 text or null, write with { ok: true }, and invalid requests reply with a descriptive error.

ConfigFiles owns filename validation and file IO against Config.dir. Reject empty names, dot names, any double dots, slash, backslash or NUL, directories and symbolic links. Writes cannot target config.yml or default.yml, including case variants on case-insensitive filesystems. Write atomically so partial content is never published.

The shared FolderWatcher maps paths to distinct direct child names and sends tilr:config { name } through Tab.send. Check the destination both before scheduling and inside JavaScript to prevent delivery after navigation to a foreign page. Keep the existing config.yml reload. The default watch latency is 0.2 seconds.
