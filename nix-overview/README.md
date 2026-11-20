# Nix Overview

NixOS at a glance in the bar: the current generation, when you last
switched, the closure and store size, free disk space, whether a reboot is
needed, and how many commits the running system is behind your flake's
remote branch.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jdmacd/nix-overview` |
| Entries | Service: `service`; bar widget: `status`; panel: `panel` |
| Plugin API | 48 (Noctalia 5.5+) |

## Requirements

NixOS, with `nix`, `nixos-version`, `readlink`, `stat` and (for the config
check) `git` on `PATH`. The panel's Clean button defaults to
[`nh`](https://github.com/nix-community/nh) `clean all`; change or clear it in
the settings.

### Config check

The config check compares the revision the running system was built from with
a remote branch of your flake. NixOS only records that revision when the
flake sets it, for example in a module every host imports:

```nix
{ inputs, ... }:
{
  system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;
}
```

`nixos-version --configuration-revision` then prints it (with a `-dirty`
suffix for a dirty tree). This puts the commit into the system closure, so
every commit produces a new generation on the next switch.

Then set **Flake checkout** to a git checkout of that flake. The plugin
fetches its remote on an interval and runs
`git rev-list --left-right --count <running>...<remote branch>`. It never
evaluates the flake, so the check costs milliseconds rather than the
minute and gigabytes a full NixOS evaluation takes.

For a flake that builds several hosts, set **Count commits touching** to the
paths that affect this host (say `nix/hosts/myhost`, `nix/modules`,
`flake.lock`). Commits to other hosts' directories then stop counting.

## What it shows

**Bar widget.** A snowflake plus text from **Bar text**, by default
`{generation} · {disk_free}` (for example `420 · 24.0 GiB`). Markers in front:

- `↻` a reboot is needed: the booted kernel, initrd or kernel modules differ
  from the current system's. A switch that didn't touch them doesn't count.
- `↓N` the running system is N commits behind the remote branch.

The icon turns red for a needed reboot or low disk space, and uses the primary
color when behind. The tooltip lists every figure.

**Panel** (click the widget):

- reboot and config status, with the running revision
- current generation, generations on disk and time since the last switch
- current system closure size
- store size and path count, and when they were counted
- free disk space where `/nix/store` lives, with a usage bar
- the last eight system generations with their dates, and the Home Manager
  generation count when there is a standalone profile
- buttons: **Update** and **Optimise** (when their commands are set),
  **Clean**, and **Recount** (sum the store now). Commands run in a terminal
  that stays open until you press Enter.

The header buttons refresh (including a fetch) and open the settings.

## How it collects

| Figure | Source | When |
| --- | --- | --- |
| Generations, last switch | `listDir`, `stat`, `readlink` on `/nix/var/nix/profiles` | every minute |
| Reboot needed | `readlink -m` on `/run/{booted,current}-system/{kernel,initrd,kernel-modules}` | every minute |
| Disk free | Noctalia's disk monitor | every minute |
| Closure | `nix path-info --closure-size /run/current-system` (under a second) | when the current system changes |
| Store size | `nix path-info --all --size`, summed by `awk`, under `nice` (several seconds) | daily (setting), after generations change (at most every 10 min), on request |
| Config | `nixos-version --configuration-revision`, `git fetch`, `git rev-list` | fetch on its interval; compare every minute |

The store size is the sum of NAR sizes, which is before hard-link
deduplication by `nix store optimise`, so on an optimised store it is larger
than the space actually used. The disk figure is what the filesystem reports.

Each check runs one command at a time with a timeout, and a watchdog frees a
check whose callback never returned, so a stuck command can't block later
refreshes. A failed fetch (offline) compares against what was last fetched
and retries at the next interval. After a resume from suspend everything
refreshes.

## IPC

```sh
noctalia msg plugin jdmacd/nix-overview:service all refresh   # refresh, including a fetch
noctalia msg plugin jdmacd/nix-overview:service all recount   # sum the store now
noctalia msg plugin jdmacd/nix-overview:service all dump      # log the snapshot as JSON
noctalia msg panel-toggle jdmacd/nix-overview:panel
```

## Settings

| Setting | Default | |
| --- | --- | --- |
| `flake_dir` | empty | Flake checkout; empty turns the config check off |
| `remote_ref` | `origin/main` | Branch to compare with |
| `watch_paths` | `[]` | Only count commits touching these pathspecs |
| `fetch_minutes` | `30` | Fetch interval; `0` never fetches |
| `store_check_hours` | `24` | Store recount interval; `0` only on request or after generations change |
| `low_disk_gib` | `10` | Free space below which the icon turns red |
| `update_command` | empty | Panel Update button, for example `nh os switch ~/flake` |
| `clean_command` | `nh clean all` | Panel Clean button |
| `optimise_command` | empty | Panel Optimise button, for example `nix store optimise` |
| `keep_terminal_open` | `true` | Wait for Enter after a command |
| `text_format` (widget) | `{generation} · {disk_free}` | Placeholders: `{generation}`, `{generations}`, `{closure}`, `{store}`, `{store_paths}`, `{disk_free}`, `{behind}` |
| `show_markers` (widget) | `true` | Show `↻` and `↓N` |

## Development

The pure modules in `lib/` have unit tests:

```sh
nix shell nixpkgs#luau -c nix-overview/scripts/test
```

`lib/` modules don't `require` each other, because Noctalia needs
`./lib/x.luau` while the `luau` CLI the tests run on resolves only `./lib/x`.

## Credits

Ideas and structure borrowed from two community plugins:
[`mindnbytes/nix-status`](https://github.com/noctalia-dev/community-plugins/tree/main/nix-status)
(service/widget/panel split, testable `lib/` modules, argv commands, the
reboot marker) and
[`avivbintangaringga/nix-monitor`](https://github.com/noctalia-dev/community-plugins/tree/main/nix-monitor)
(store and closure figures, stat cards, terminal command buttons).

## Changelog

- 0.1.0: first release.
