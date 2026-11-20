# noctalia-plugins

Plugins for the [Noctalia](https://github.com/noctalia-dev/noctalia) shell.

| Plugin | Description |
| --- | --- |
| [Immich Wallpaper](immich-wallpaper/) | Keeps wallpaper folders filled with photos from an [Immich](https://immich.app) library, picked ImmichFrame-style by album, people, tag, favorite and memory, for Noctalia's wallpaper rotation and lock screen. |
| [Nix Overview](nix-overview/) | NixOS at a glance: generation, last switch, closure, store and disk size, whether a reboot is needed, and how far the running system is behind your flake's remote branch. |

## Installing

In Noctalia, open Settings → Plugins → Sources → **Add Source**, choose
**Git**, and use:

```
https://github.com/jDmacD/noctalia-plugins
```

Or from a terminal:

```sh
noctalia msg plugins source add jdmacd git https://github.com/jDmacD/noctalia-plugins
```

Then enable the plugin under Settings → Plugins. Each plugin's README covers
its setup.

For development, clone the repo and add it as a **Path** source pointing at
the repo root (the directory that contains the plugin folders). `.luau` edits
reload automatically; `plugin.toml` changes need the plugin toggled off and
on.

## Layout

```
<plugin>/                 one directory per plugin, named after its id
  plugin.toml             manifest
  *.luau                  entry scripts
  translations/en.json    every label_key / description_key
  README.md
catalog.toml              generated index for git sources
scripts/update-catalog.py regenerates catalog.toml
```

After adding a plugin or bumping a version, run
`python3 scripts/update-catalog.py` and commit `catalog.toml`.

## License

MIT. See [LICENSE](LICENSE).
