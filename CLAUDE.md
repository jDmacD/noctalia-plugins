# CLAUDE.md

Guidance for working on this repo: Noctalia shell plugins written in Luau.

## Repo layout

- One directory per plugin, named after the part of its id after `/`
  (`jdmacd/immich-wallpaper` lives in `immich-wallpaper/`).
- `catalog.toml` is **generated**: run `python3 scripts/update-catalog.py`
  after adding a plugin or changing any manifest field it copies (version,
  description, tags, plugin_api…). Noctalia refuses a git source without it;
  path sources ignore it.
- This repo is **public**. Keep hostnames, IPs, server URLs, API keys and
  other details of anyone's setup out of code, docs, examples and commit
  messages. Use `photos.example.com`-style placeholders.

## Noctalia plugin API: facts that matter

The authoritative docs are in the Noctalia source repo under
`docs/user/plugins/development/` (`runtime-api.mdx`, `manifest.mdx`,
`entries.mdx`, `declarative-ui.mdx`). When behaviour isn't documented, read
`src/scripting/luau_host.cpp` and `src/scripting/plugin_api.h` at the tag of
the Noctalia version being targeted. The docs on the website track `main`
and can be ahead of released versions.

- **`plugin_api`:** declare the oldest level that has everything the plugin
  uses. The supported range per Noctalia version is in `plugin_api.h`
  (`kCurrentPluginApiVersion`). Example: 5.4.1 tops out at 43, so `secret`
  settings (47) and `onResume` (48) aren't available there. Functions above
  the declared level may exist but are never called.
- **CPU budget:** every script callback (including HTTP callbacks) gets
  **25 ms of thread CPU time** (`kCallBudget` in `script_runtime.cpp`); the
  top-level load gets 100 ms. Exceeding it kills the callback with
  `exceeded its CPU budget`, and the rest of the callback never runs, so
  never leave "busy" flags that only the callback clears; add a watchdog.
  `json.decode` of a few hundred rich objects is enough to blow it on a
  laptop CPU. Keep API responses small (paginate or request few items).
- **HTTP:** `noctalia.http` supports `method`, `body` and `headers`, has a
  30 s timeout, no size cap, and returns a **binary-safe** `body`.
  `noctalia.writeFile` is binary-safe too, so downloading with auth headers
  is `http` + `writeFile`. `noctalia.download(url, dest, cb)` **cannot send
  headers**. Prefer native HTTP over spawning curl so secrets stay off
  command lines.
- **Wallpaper:** `setWallpaper(path)` / `setWallpaper(connector, path)`
  persist to `~/.local/state/noctalia/settings.toml`. Built-in rotation
  rescans its folder on every tick and overwrites every monitor's path, so
  per-monitor paths set by a plugin don't stick past the next rotation.
  `wallpaperDirectory()` returns the effective folder: Light/Dark Mode
  Directories override Wallpaper Directory, and per-monitor directories
  override both when enabled. Supported image extensions: jpg, jpeg, png,
  webp, jxl, bmp, gif, heic, heif, avif. HEIF/AVIF need `libheif` loadable at
  runtime, which Nix builds may lack.
- **Lock screen:** draws the desktop wallpaper and follows changes live
  unless a custom lock wallpaper is set. Plugin desktop widgets can be placed
  as lock screen widgets.
- **Desktop widgets** don't know which output they're on.
- **Settings:** `string_list` values come back as Luau arrays.
  `visible_when` and `advanced` work at low API levels. Every `label_key` and
  `description_key` must exist in `translations/en.json`.
- **Logging:** `noctalia.log` lines land in `~/.cache/noctalia/noctalia.log`
  tagged `[script-runtime]` (`grep -a`, the file has binary bytes). Script
  errors show as `[ERR] [luau] plugin <id>:<entry>: …`.

## Development workflow

1. Add the repo root as a **Path** source in Noctalia (Settings → Plugins →
   Sources). `.luau` edits hot-reload; `plugin.toml` changes need the plugin
   toggled off and on, and a toggle prints `unknown setting` warnings for
   settings removed from the manifest.
2. Type-check before syncing anywhere:
   ```sh
   nix-shell -p luau --run 'luau-analyze --formatter=plain <plugin>/*.luau'
   ```
   Expected noise: `Unknown global 'noctalia'` / `'ui'` / `'desktopWidget'`,
   `FunctionUnused` for host callbacks (`update`, `onIpc`, `onConfigChanged`),
   and `TableOperations` on `#res.body`.
3. The `luau` CLI has no file I/O. To unit-test pure functions, generate a
   script that inlines test data as string literals.
4. Test on the real device and read the log. Most bugs in this repo showed up
   only against a live server: permissions (403s), CPU budget, name
   resolution.
5. Bump the plugin's `version` (semver) for user-visible changes, add a
   changelog line to its README, regenerate `catalog.toml`.

The community repo's validator lives in `noctalia-dev/official-plugins`
under `.github/actions/validate-plugins/`
(`validate-plugins.py --profile community --root <repo>`, needs
`langdetect`). Run it before proposing a plugin to
`noctalia-dev/community-plugins`, which also requires a `thumbnail.webp`.

## immich-wallpaper specifics

- Needs Immich ≥ 3.2 (search `filter` with `or` branches, `IdsFilter.none`,
  `rating.gte`). Immich publishes its OpenAPI spec at `/api/spec.json` on
  every server, which is the quickest way to check request shapes for a
  given version.
- Each new photo is one `/search/random` with `size = 15`; never go back to a
  big pool (that blew the CPU budget).
- `photos.json` (plugin data dir) is versioned (`version = 3`); `loadIndex`
  migrates 0.1/0.2 formats. Keep migrations when changing it.
- Anything that changes which photos qualify must go into `selectionKey()`
  (that's what triggers a folder refill), but keep defaults out of the key
  (`nil` when default) so upgrades don't refill everyone's folders.
- Only delete files matching `<uuid>.<ext>`, and never the wallpaper on
  screen (`inUse()`).
