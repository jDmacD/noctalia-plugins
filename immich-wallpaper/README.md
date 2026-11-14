# Immich Wallpaper

Keeps one or more wallpaper folders filled with photos from a self-hosted
[Immich](https://immich.app) library. Noctalia's own wallpaper rotation picks
from those folders, and the lock screen shows whatever wallpaper is current,
so your desktop and lock screen become a photo frame.

Photos are chosen with the same options as
[ImmichFrame](https://immichframe.dev): albums, people, tags, favorites and
memories, narrowed by date, rating and excluded albums. An optional desktop
widget shows the current photo's date, place and people.

## Plugin

| Field | Value |
| --- | --- |
| ID | `jdmacd/immich-wallpaper` |
| Entries | Service: `service`; desktop widget: `caption` |
| Plugin API | 25 (Noctalia 5.x) |

## Requirements

- **Immich v3.2 or newer.** The plugin uses the search `filter` object added
  in v3.2.
- **An Immich API key** with these permissions:

  | Permission | Needed for |
  | --- | --- |
  | `asset.read` | searching for photos |
  | `asset.view` | downloading previews |
  | `asset.download` | the **Full size** and **Original** image sizes |
  | `album.read` | album names and IDs |
  | `person.read` | people by name |
  | `tag.read` | tags |
  | `memory.read` | memories |

  A key with only the permissions you use is fine. A missing one shows up in
  the log as `HTTP 403 {"message":"Missing required permission: …"}`.
- **For HEIC/HEIF/AVIF originals only:** Noctalia must be able to load
  `libheif` at runtime (with an HEVC decoder such as libde265 for HEIC). See
  [Image size](#image-size).

No external commands are used.

## Installation

The plugin lives in the
[`jDmacD/noctalia-plugins`](https://github.com/jDmacD/noctalia-plugins)
source repo. In Noctalia, open Settings → Plugins → Sources → **Add Source**:

- **Git:** Location `https://github.com/jDmacD/noctalia-plugins`.
- **Path** (for development): a local clone, pointing at the repo root (the
  directory that contains `immich-wallpaper/`), not at the plugin itself.

Then enable **Immich Wallpaper** under Plugins.

## Quick start

1. In Immich, create an API key (Account Settings → API Keys) with the
   permissions above. Save it to a file only you can read:
   ```sh
   install -m 600 /dev/null ~/.config/immich-wallpaper.key
   $EDITOR ~/.config/immich-wallpaper.key   # paste the key
   ```
2. In the plugin's settings, set **Immich server URL** (for example
   `https://photos.example.com`, without `/api`) and **API key file**.
3. Optionally choose albums, people, tags or favorites (see
   [Choosing photos](#choosing-photos)). With nothing chosen, photos come from
   the whole library.
4. Set **Photo folder**, e.g. `~/Pictures/Immich`. Empty means an `immich`
   folder inside your wallpaper folder.
5. In Settings → Wallpaper:
   - Point the wallpaper folder at the photo folder. If **Light Mode
     Directory** and **Dark Mode Directory** (Advanced) are set, they take
     priority over **Wallpaper Directory**, so set those. Alternatively, keep
     your folder and turn on **Include Subfolders** to mix Immich photos with
     your other wallpapers.
   - Under Automation, turn on **Automatic Rotation** and set its interval
     and order.

The first photos arrive within seconds. On first setup, the first photo is
set as the wallpaper straight away if the current one is from outside the
photo folder (for example Noctalia's default image). After that, Noctalia's
rotation takes over. To skip to another photo at any time:

```sh
noctalia msg wallpaper-random
```

### Lock screen photo frame

Noctalia's lock screen draws the desktop wallpaper and follows it while
locked. For a clean photo frame, go to Settings → Lock screen, set **Blur
Intensity** and **Tint Intensity** to 0, and leave its custom **Wallpaper**
empty.

### Caption widget

Add the **Immich Wallpaper → caption** desktop widget to show the current
photo's date, location, named people and description. It can also be placed
on the lock screen as a lock screen widget. Each line can be turned off in
the widget's settings. It's empty when the wallpaper isn't one of the
plugin's photos.

## Choosing photos

The selection works like ImmichFrame:

- **Albums**, **People**, **Tags** and **Include favorites** add up: a photo
  matching any of them can be shown.
- **Taken on or after / before**, **Only the last N days**, **Minimum
  rating**, **Include archived photos** and **Excluded albums** narrow that
  set.
- **Include memories** adds today's Immich memories (on this day and
  birthdays), mixed in for roughly one photo in four. If memories are the only
  source set, only memories are shown.
- With none of albums, people, tags, favorites or memories set, photos come
  from the whole library.

Entries can be given:

- **By name:** `Holidays`, `Alice`. Names must match exactly (case is ignored).
  They are looked up once a day; a name that matches nothing is reported in
  the log and as a notification.
- **By ID:** the UUID from Immich's `/api/albums` or `/api/people`, or from the
  web UI's URL when you open an album or person.
- **Tags by path:** `Vacation`, `Travel/Europe` (case-sensitive).

Anything after `#` in an entry is ignored, so `0f7c2a9e-… # Holidays` keeps a
note next to an ID.

If albums, people or tags are set but none of them can be found, nothing is
fetched. The plugin never silently falls back to the whole library.

**Landscape photos only** (on by default) skips portrait photos. With a small
album this can leave the folder with fewer photos than **Photos in the
folder**. Turn it off to include portraits.

### One folder per monitor

With **Per-Monitor Directories** on in Settings → Wallpaper, each monitor can
rotate through its own folder. End an album, people or tag entry with
`:<folder>` to send its photos there:

```
Albums:  Holidays:~/Pictures/Immich/eDP-1
         Garden:~/Pictures/Immich/DP-2
People:  Alice:~/Pictures/Immich/DP-2
```

Then, under Settings → Wallpaper → Monitors, set each monitor's Light and Dark
Mode Directory to its folder.

- Entries for the same folder add up, like the main selection.
- Entries without a suffix, favorites and memories go to the main **Photo
  folder**. If every entry has a suffix and favorites and memories are off,
  the main folder is left alone.
- Dates, rating, archived photos, landscape-only, image size and excluded
  albums apply to every folder.
- The folder must start with `/` or `~`, so album names containing `:` still
  work.

## How the folders are kept

- Each folder is filled up to **Photos in the folder** photos, one download
  about every 5 seconds.
- After that, the oldest photo is swapped for a new random one every **Swap in
  a new photo every** minutes, so the folder slowly works through the whole
  selection. New photos added to your albums show up this way without a
  refresh.
- When a folder's selection changes (albums, people, tags, filters, image
  size), it is emptied and refilled. A screen still showing an old photo is
  switched to the first new one as soon as it arrives.
- If a selection has fewer matching photos than the folder can hold, the
  plugin logs it and checks back with increasing gaps (up to 10 minutes).
- The photo on screen is never deleted.
- Only files named `<asset-id>.<ext>` are ever deleted, so a shared wallpaper
  folder is safe.

## Image size

Immich can't convert images per request. Every size except the original is
generated ahead of time, in the format and quality set under Administration →
Settings → Image Settings.

| Option | What's downloaded |
| --- | --- |
| **Preview** (default) | Immich's preview: JPEG or WebP, 1440 px on the short edge by default. Small and fast, fine for laptop screens. |
| **Full size** | Immich's full-resolution JPEG/WebP. Immich only generates it for originals a browser can't show (HEIC, RAW), and only with **Generate full-size image** on. For JPEG originals, Immich serves the original instead. |
| **Original** | The uploaded file. |

For **Original**:

- Noctalia displays JPEG, PNG, WebP, JPEG XL, GIF and BMP directly, and
  applies EXIF orientation.
- HEIC, HEIF and AVIF need libheif. They are only kept as originals with
  **HEIC/AVIF originals** on; otherwise they're fetched as full size. Turn it
  on only if Noctalia can load libheif. Noctalia's log says
  `libheif.so.1 not available` when it can't, and the wallpaper then shows
  blank.
- RAW files and originals over 50 MB are fetched as full size.

**Full size** and **Original** need the `asset.download` permission.

When full size is asked for but Immich only has its preview (typically a
HEIC photo before Generate full-size image was turned on), the photo is saved
at preview size and re-fetched every hour until a full-size version exists.
The plugin detects this by comparing the downloaded image's pixel size with
the original's. To get full-size images for existing photos, turn on Generate
full-size image and run the **Missing** thumbnail job under Administration →
Jobs; the photos upgrade at the next hourly check.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `server_url` | `string` | | Immich base URL, without `/api`. |
| `api_key_file` | `file` | | File holding the API key (preferred). |
| `api_key` | `string` | | API key in plain text in the Noctalia config (advanced). Ignored when a key file is set. |
| `albums` | `string_list` | `[]` | Album names or IDs; `:<folder>` suffix picks the folder. |
| `people` | `string_list` | `[]` | Person names or IDs; `:<folder>` suffix picks the folder. |
| `tags` | `string_list` | `[]` | Tag paths (case-sensitive); `:<folder>` suffix picks the folder. |
| `show_favorites` | `bool` | `false` | Include favorites (main folder). |
| `show_memories` | `bool` | `false` | Include today's memories (main folder). |
| `show_on_this_day_memories` | `bool` | `true` | "On this day" memories. |
| `show_birthday_memories` | `bool` | `true` | Birthday memories. |
| `excluded_albums` | `string_list` | `[]` | Album names or IDs never shown. |
| `images_from_days` | `int` | `0` | Only photos from the last N days (0 = off). |
| `images_from_date` | `string` | | `YYYY-MM-DD`; overrides `images_from_days`. |
| `images_until_date` | `string` | | `YYYY-MM-DD`. |
| `rating` | `int` | `0` | Minimum star rating (0 = off). |
| `show_archived` | `bool` | `false` | Include archived photos. |
| `cache_size` | `int` | `30` | Photos kept in each folder. |
| `folder` | `folder` | | Main photo folder; empty means `<wallpaper folder>/immich`. |
| `churn_minutes` | `int` | `30` | How often one photo per folder is replaced. |
| `landscape_only` | `bool` | `true` | Only keep landscape photos. |
| `image_size` | `select` | `preview` | `preview`, `fullsize` or `original`. |
| `heif_originals` | `bool` | `false` | With `original`, keep HEIC/HEIF/AVIF originals (needs libheif). |
| `photo_date_format` | `string` | `%d %B %Y` | `os.date` format for the caption date (advanced). |
| `caption.show_photo_date` | `bool` | `true` | Caption: date. |
| `caption.show_image_location` | `bool` | `true` | Caption: city, state, country. |
| `caption.show_people_desc` | `bool` | `true` | Caption: named people. |
| `caption.show_image_desc` | `bool` | `true` | Caption: description. |
| `caption.max_width` | `int` | `360` | Caption width in logical pixels. |

## IPC

```sh
# Rebuild the folder list, look names up again and re-check selections
noctalia msg plugin jdmacd/immich-wallpaper:service all refresh
# Fetch now, skipping any back-off (e.g. after fixing a permission)
noctalia msg plugin jdmacd/immich-wallpaper:service all fetch
```

## Troubleshooting

The plugin logs every action and error to Noctalia's log
(`~/.cache/noctalia/noctalia.log`), prefixed `Immich Wallpaper:`:

```sh
grep -a "Immich Wallpaper" ~/.cache/noctalia/noctalia.log | tail
```

Errors also appear as a notification, at most once an hour.

| Symptom | Cause and fix |
| --- | --- |
| `HTTP 403 … Missing required permission: asset.view` | Add `asset.view` to the API key. |
| `HTTP 403 … Missing required permission: asset.download` | Add `asset.download`, or use the Preview image size. |
| `No album named "…"` / `No person named "…"` | The name doesn't match exactly. Check spelling, or use the ID. |
| `Nothing configured for … was found in Immich` | None of the albums, people or tags for that folder exist. |
| `searches keep returning photos already saved` | The selection has fewer photos than **Photos in the folder**. Not an error. |
| Photos download but the wallpaper doesn't change | Turn on **Automatic Rotation**, and check which folder Noctalia uses. Light/Dark Mode Directories, and per-monitor directories when on, override **Wallpaper Directory**. |
| Wallpaper blank on some photos | `.heic`/`.avif` files without libheif. Turn off **HEIC/AVIF originals**. |
| Photos stay at 1920×1440 with Full size or Original | Immich has no full-size image yet. Turn on Generate full-size image in Immich and run the Missing thumbnail job. |
| Changes to albums don't show up | Folders refill when the selection changes, and the screen switches when the first new photo arrives. Check the log for errors. |
| `unknown setting` warnings for `pool_size` / `refresh_hours` | Left over from version 0.1. Delete those lines from `[plugin_settings."jdmacd/immich-wallpaper"]` in `~/.local/state/noctalia/settings.toml`. |

## How it works

- **Search:** each new photo comes from a small
  `POST /api/search/random` request (15 results) using Immich's v3.2 search
  `filter`, with the selection expressed as `or` branches and the narrowing
  filters at the top level. Requests stay small because Noctalia gives every
  script callback a 25 ms CPU budget, and decoding hundreds of assets at once
  exceeds it.
- **Download:** images are fetched with Noctalia's built-in HTTP client, with
  the key in the `x-api-key` header, so it never appears on a command line.
  Each download is written to a `.part` file and renamed, so the rotation
  never sees a half-written image. The file type is detected from its first
  bytes.
- **Captions and state:** caption details, the selection each folder was
  filled with, and low-resolution flags live in `photos.json` in the plugin's
  data directory (`~/.local/state/noctalia/plugins/…`).
- **Caption widget:** the service publishes the current photo's details
  through `noctalia.state`. Desktop widgets don't know which monitor they're
  on, so the caption follows the first monitor.

### Network

| Request | When |
| --- | --- |
| `POST /api/search/random` | Once per new photo |
| `GET /api/assets/{id}/thumbnail?size=preview\|fullsize` or `GET /api/assets/{id}/original` | Once per new photo |
| `GET /api/albums?name=`, `GET /api/search/person?name=` | Daily, once per name-based entry |
| `GET /api/tags` | Daily, when tags are set |
| `GET /api/memories?for=<date>` | Daily, when memories are on |
| `GET /api/assets/{id}` | Hourly per photo awaiting a full-size version |

All requests go only to the configured server.

## Limitations

- Videos are never used.
- With wallpaper-derived color schemes, the shell recolors with every photo.
- The caption describes the first monitor's wallpaper only.
- Rotation timing is Noctalia's; the plugin only changes the wallpaper itself
  when a selection changes and on first setup.

## Changelog

- **0.5.0:** re-fetch photos that came back at preview size when full size
  was asked for.
- **0.4.1:** **HEIC/AVIF originals** setting; HEIC files are removed when it's
  off; 15 results per search.
- **0.4.0:** **Image size** setting (preview, full size, original).
- **0.3.0:** `:<folder>` suffix for per-monitor folders; strict landscape-only.
- **0.2.0:** album and person names; folder refills when the selection
  changes; switches stale wallpapers immediately.
- **0.1.0:** first version.
