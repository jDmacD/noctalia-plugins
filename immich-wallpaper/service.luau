--!nonstrict
-- Immich Wallpaper service.
--
-- Keeps one or more folders filled with preview images from Immich for
-- Noctalia's own wallpaper automation to rotate through (the lock screen
-- draws whatever wallpaper is current), and publishes the current photo's
-- caption for the desktop widget.
--
-- Selection follows ImmichFrame: albums, people, tags and favorites add up
-- (OR); dates, rating, archived and excluded albums narrow that set (AND).
-- With nothing set, the whole library is used.
--
-- An album/person/tag entry may end in ":<folder>" (e.g.
-- "Holidays:~/Pictures/Immich/eDP-1") to fill that folder instead of the main
-- one, for Noctalia's per-monitor wallpaper directories. Each folder is a
-- "target" with its own selection, photos and refresh.
--
-- Each new photo comes from a small /api/search/random request, so every
-- response stays tiny: script callbacks get a 25 ms CPU budget, and decoding
-- hundreds of assets at once blows it.
--
-- Images are fetched with the x-api-key header through Noctalia's native
-- HTTP client (no curl, so the key never appears on a command line).
--
-- Requires Immich v3.2+ for the search `filter` object.

local TICK_MS = 5 * 1000
local SEARCH_SIZE = 15
local BUSY_TIMEOUT = 120 -- seconds; resets flags if a callback was killed
local ERROR_NOTIFY_SECONDS = 60 * 60
local INDEX_FILE = "photos.json"
local MAX_MEMORY_BYTES = 512 * 1024
local RETRY_SECONDS = 60 * 60 -- re-fetch photos that came back at preview size
local EDIT_CHECK_SECONDS = 6 * 60 * 60 -- re-check saved photos for Immich edits

-- Targets, rebuilt from settings on every reset:
--   { folder, albums = {entries}, people = {...}, tags = {...},
--     favorites, memories, main, owned = {{id, path, mtime}}, selection,
--     lastChurn, lastAttempt, misses }
local targets = {}
local photos = {} -- path -> caption info (+ selection), persisted
local selections = {} -- folder -> selection key the folder was filled with, persisted
local legacyById = nil -- 0.1/0.2 index (id -> info), migrated on scan
local busySince = 0 -- non-zero while a search or download is in flight
local rr = 0 -- round-robin cursor over targets
local lastCurrentPath = nil
local lastErrorNotify = 0

-- Refreshed once a day (or on config change).
local dailyKey = ""
local dailyLoading = false
local lookupFailed = false
local idsByName = { album = {}, person = {}, tag = {} } -- name/path -> {ids}
local memories = {} -- caption infos for today's memories

noctalia.setUpdateInterval(TICK_MS)

-- ---------------------------------------------------------------------------
-- Helpers

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

local function trim(s)
  if type(s) ~= "string" then
    return ""
  end
  return noctalia.string.trim(s)
end

local function list(key)
  local v = noctalia.getConfig(key)
  local out = {}
  if type(v) == "table" then
    for _, item in ipairs(v) do
      -- Allow "uuid # comment" entries, as in ImmichFrame configs.
      local s = trim((trim(item):gsub("#.*$", "")))
      if s ~= "" then
        table.insert(out, s)
      end
    end
  end
  return out
end

local function setStatus(state, extra)
  local status = { state = state }
  if type(extra) == "table" then
    for k, v in pairs(extra) do
      status[k] = v
    end
  end
  noctalia.state.set("status", status)
end

local function fail(message)
  noctalia.log(`Immich Wallpaper: {message}`)
  setStatus("error", { message = message })
  local now = os.time()
  if now - lastErrorNotify >= ERROR_NOTIFY_SECONDS then
    lastErrorNotify = now
    noctalia.notifyError(noctalia.tr("notify.failed"), message)
  end
end

local function serverUrl()
  local url = trim(cfg("server_url", ""))
  url = url:gsub("/+$", "")
  url = url:gsub("/api$", "")
  return url
end

local function apiKey()
  local file = trim(cfg("api_key_file", ""))
  if file ~= "" then
    local content = noctalia.readFile(noctalia.expandPath(file))
    if type(content) == "string" then
      local key = trim(content)
      if key ~= "" then
        return key
      end
    end
    return nil, `Could not read the API key file {file}`
  end
  local key = trim(cfg("api_key", ""))
  if key == "" then
    return nil, nil
  end
  return key, nil
end

local function excerpt(body)
  if type(body) ~= "string" then
    return ""
  end
  body = body:gsub("%s+", " ")
  if #body > 300 then
    body = body:sub(1, 300) .. "…"
  end
  return body
end

-- JSON API call. `maxBytes` refuses to decode oversized bodies (decoding
-- runs inside the callback's CPU budget).
local function api(method, path, body, maxBytes, cb)
  local base = serverUrl()
  local key = apiKey()
  if base == "" or key == nil then
    cb(nil, "not configured")
    return
  end
  local headers = { `x-api-key: {key}`, "Accept: application/json" }
  local encoded = ""
  if body ~= nil then
    encoded = noctalia.json.encode(body)
    table.insert(headers, "Content-Type: application/json")
  end
  local started = noctalia.http({
    url = `{base}/api{path}`,
    method = method,
    body = encoded,
    headers = headers,
    follow_redirects = true,
  }, function(res)
    if not res.ok or res.status < 200 or res.status >= 300 then
      cb(nil, `{method} {path}: HTTP {res.status} {excerpt(res.body)}`)
      return
    end
    if maxBytes ~= nil and #res.body > maxBytes then
      cb(nil, `{method} {path}: response too large ({#res.body} bytes)`)
      return
    end
    local parsed, err = noctalia.json.decode(res.body)
    if parsed == nil then
      cb(nil, `{method} {path}: bad JSON ({err or "?"})`)
      return
    end
    cb(parsed, nil)
  end)
  if not started then
    cb(nil, `{method} {path}: request not started`)
  end
end

-- ---------------------------------------------------------------------------
-- Asset metadata

local function isoDate(t)
  return os.date("!%Y-%m-%dT%H:%M:%S.000Z", t)
end

local function dateSetting(key, endOfDay)
  local s = trim(cfg(key, ""))
  if s == "" then
    return nil
  end
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if y == nil then
    fail(`{key} must be YYYY-MM-DD, got "{s}"`)
    return nil
  end
  return `{y}-{m}-{d}T{endOfDay and "23:59:59.999" or "00:00:00.000"}Z`
end

local function formatPhotoDate(iso)
  if type(iso) ~= "string" then
    return ""
  end
  local y, m, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y == nil then
    return ""
  end
  local t = os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local ok, out = pcall(os.date, cfg("photo_date_format", "%d %B %Y"), t)
  if ok and type(out) == "string" then
    return out
  end
  return `{d}/{m}/{y}`
end

-- The display size (EXIF orientations 5-8 rotate by 90°; previews are
-- already upright), or nil when Immich doesn't know it. An edited asset's
-- width/height are those of the edited, upright image, while EXIF keeps the
-- original's.
local function orientedSize(asset)
  if asset.isEdited and tonumber(asset.width) and tonumber(asset.height) then
    return tonumber(asset.width), tonumber(asset.height)
  end
  local exif = asset.exifInfo or {}
  local w = tonumber(exif.exifImageWidth) or tonumber(asset.width)
  local h = tonumber(exif.exifImageHeight) or tonumber(asset.height)
  if w == nil or h == nil then
    return nil, nil
  end
  local o = tostring(exif.orientation or "")
  if o == "5" or o == "6" or o == "7" or o == "8" or o:find("90") or o:find("270") then
    w, h = h, w
  end
  return w, h
end

local function isLandscape(asset)
  local w, h = orientedSize(asset)
  if w == nil then
    return true
  end
  return w >= h
end

local function assetInfo(asset)
  local exif = asset.exifInfo or {}

  local place = {}
  local seen = {}
  for _, part in ipairs({ exif.city, exif.state, exif.country }) do
    if type(part) == "string" and part ~= "" and not seen[part] then
      seen[part] = true
      table.insert(place, part)
    end
  end

  local names = {}
  if type(asset.people) == "table" then
    for _, person in ipairs(asset.people) do
      if type(person) == "table" and type(person.name) == "string" and person.name ~= "" and not person.isHidden then
        table.insert(names, person.name)
      end
    end
  end

  return {
    id = asset.id,
    date = formatPhotoDate(exif.dateTimeOriginal or asset.localDateTime or asset.fileCreatedAt),
    location = table.concat(place, ", "),
    people = table.concat(names, ", "),
    description = type(exif.description) == "string" and trim(exif.description) or "",
    landscape = isLandscape(asset),
    mime = type(asset.originalMimeType) == "string" and asset.originalMimeType:lower() or "",
    w = (orientedSize(asset)),
    h = select(2, orientedSize(asset)),
    bytes = tonumber(exif.fileSizeInByte) or 0,
    edited = asset.isEdited == true,
    updatedAt = type(asset.updatedAt) == "string" and asset.updatedAt or nil,
  }
end

local function acceptAsset(asset)
  if type(asset) ~= "table" or type(asset.id) ~= "string" then
    return false
  end
  if asset.type ~= nil and asset.type ~= "IMAGE" then
    return false
  end
  if asset.isTrashed then
    return false
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Targets: which folder gets which selection

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
local UUID_FILE = "^(%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x)%.(%a+)$"

local function isUuid(s)
  return s:match(UUID) ~= nil
end

local function normalizeFolder(path)
  local expanded = noctalia.expandPath(trim(path))
  return (expanded:gsub("/+$", ""))
end

-- "Holidays:~/Pictures/Immich/eDP-1" -> "Holidays", "/home/…/eDP-1".
-- The folder must start with / or ~, so names containing ":" still work.
local function splitEntry(entry)
  local name, folder = entry:match("^(.-)%s*:%s*([~/].*)$")
  if name ~= nil and trim(name) ~= "" then
    return trim(name), normalizeFolder(folder)
  end
  return entry, nil
end

local function mainFolder()
  local configured = trim(cfg("folder", ""))
  if configured ~= "" then
    return normalizeFolder(configured)
  end
  local base = noctalia.wallpaperDirectory()
  if base == nil or base == "" then
    base = "~/Pictures/Wallpapers"
  end
  return normalizeFolder(base) .. "/immich"
end

local function hasSources(t)
  return #t.albums > 0 or #t.people > 0 or #t.tags > 0 or t.favorites
end

local function memoriesOnly(t)
  return t.memories and not hasSources(t)
end

local function buildTargets()
  local byFolder = {}
  local ordered = {}
  local main = mainFolder()
  local function get(folder)
    local t = byFolder[folder]
    if t == nil then
      t = {
        folder = folder,
        main = folder == main,
        albums = {},
        people = {},
        tags = {},
        favorites = false,
        memories = false,
        owned = {},
        selection = "",
        lastChurn = os.time(),
        lastAttempt = 0,
        misses = 0,
      }
      byFolder[folder] = t
      table.insert(ordered, t)
    end
    return t
  end

  for _, spec in ipairs({ { "albums", "albums" }, { "people", "people" }, { "tags", "tags" } }) do
    for _, entry in ipairs(list(spec[1])) do
      local name, folder = splitEntry(entry)
      table.insert(get(folder or main)[spec[2]], name)
    end
  end

  local favorites = cfg("show_favorites", false)
  local showMemories = cfg("show_memories", false)
  if favorites then
    get(main).favorites = true
  end
  if showMemories then
    get(main).memories = true
  end
  -- Nothing configured at all: the main folder gets the whole library.
  if #ordered == 0 then
    get(main)
  end
  targets = ordered
end

local function sharedFilterKey()
  return {
    excluded = list("excluded_albums"),
    onThisDay = cfg("show_on_this_day_memories", true),
    birthday = cfg("show_birthday_memories", true),
    fromDays = cfg("images_from_days", 0),
    fromDate = trim(cfg("images_from_date", "")),
    untilDate = trim(cfg("images_until_date", "")),
    rating = cfg("rating", 0),
    archived = cfg("show_archived", false),
    landscape = cfg("landscape_only", true),
    -- Only when non-default, so existing folders aren't refilled on upgrade.
    imageSize = cfg("image_size", "preview") ~= "preview" and cfg("image_size", "preview") or nil,
    heif = cfg("heif_originals", false) or nil,
    server = serverUrl(),
  }
end

-- Everything that decides which photos qualify for a target. When it
-- changes, that folder is emptied and refilled.
local function selectionKey(t)
  return noctalia.json.encode({
    albums = t.albums,
    people = t.people,
    tags = t.tags,
    favorites = t.favorites,
    memories = t.memories,
    shared = sharedFilterKey(),
  }) or ""
end

-- ---------------------------------------------------------------------------
-- Names -> ids (albums, people, tags), refreshed daily

local function idsFor(kind, entries)
  local out = {}
  for _, entry in ipairs(entries) do
    if kind ~= "tag" and isUuid(entry) then
      table.insert(out, entry)
    else
      for _, id in ipairs(idsByName[kind][entry] or {}) do
        table.insert(out, id)
      end
    end
  end
  return out
end

local function excludedEntries()
  local out = {}
  for _, entry in ipairs(list("excluded_albums")) do
    local name = splitEntry(entry) -- a folder suffix means nothing here
    table.insert(out, name)
  end
  return out
end

local function resolveNames(done)
  idsByName = { album = {}, person = {}, tag = {} }
  local jobs = {}
  local seen = {}
  local function want(kind, name)
    if kind ~= "tag" and isUuid(name) then
      return
    end
    local key = kind .. "\0" .. name
    if not seen[key] then
      seen[key] = true
      if kind ~= "tag" then
        table.insert(jobs, { kind = kind, name = name })
      end
    end
  end
  local wantTags = false
  for _, t in ipairs(targets) do
    for _, n in ipairs(t.albums) do
      want("album", n)
    end
    for _, n in ipairs(t.people) do
      want("person", n)
    end
    if #t.tags > 0 then
      wantTags = true
    end
  end
  for _, n in ipairs(excludedEntries()) do
    want("album", n)
  end

  local i = 0
  local function nextJob()
    i += 1
    local job = jobs[i]
    if job == nil then
      done()
      return
    end
    local encoded = noctalia.string.urlEncode(job.name)
    local path = job.kind == "album" and `/albums?name={encoded}` or `/search/person?name={encoded}&withHidden=false`
    api("GET", path, nil, MAX_MEMORY_BYTES, function(items, err)
      if items == nil then
        lookupFailed = true
        noctalia.log(`Immich Wallpaper: could not look up {job.kind} "{job.name}": {err}`)
      else
        local ids = {}
        local wantedName = job.name:lower()
        for _, item in ipairs(items) do
          local name = job.kind == "album" and item.albumName or item.name
          -- Person search matches prefixes; keep exact (case-insensitive) names.
          if type(item.id) == "string" and type(name) == "string" and name:lower() == wantedName then
            table.insert(ids, item.id)
          end
        end
        idsByName[job.kind][job.name] = ids
        if #ids == 0 then
          fail(`No {job.kind} named "{job.name}"`)
        end
      end
      nextJob()
    end)
  end

  if not wantTags then
    nextJob()
    return
  end
  -- Tags are configured by path ("Travel/Europe"), like ImmichFrame.
  api("GET", "/tags", nil, MAX_MEMORY_BYTES, function(tags, err)
    if tags == nil then
      lookupFailed = true
      noctalia.log(`Immich Wallpaper: tags skipped: {err}`)
    else
      for _, tag in ipairs(tags) do
        if type(tag.value) == "string" and type(tag.id) == "string" then
          idsByName.tag[tag.value] = { tag.id }
        end
      end
      for _, t in ipairs(targets) do
        for _, path in ipairs(t.tags) do
          if idsByName.tag[path] == nil then
            fail(`No tag "{path}"`)
          end
        end
      end
    end
    nextJob()
  end)
end

local function loadMemories(done)
  memories = {}
  local wanted = false
  for _, t in ipairs(targets) do
    wanted = wanted or t.memories
  end
  if not wanted then
    done()
    return
  end
  local wantOnThisDay = cfg("show_on_this_day_memories", true)
  local wantBirthday = cfg("show_birthday_memories", true)
  api("GET", `/memories?for={os.date("%Y-%m-%d")}`, nil, MAX_MEMORY_BYTES, function(result, err)
    if result == nil then
      noctalia.log(`Immich Wallpaper: memories skipped: {err}`)
      done()
      return
    end
    for _, memory in ipairs(result) do
      local kind = memory.type
      local ok = (kind == "on_this_day" and wantOnThisDay) or (kind == "birthday" and wantBirthday)
      if ok and type(memory.assets) == "table" then
        for _, asset in ipairs(memory.assets) do
          if acceptAsset(asset) then
            table.insert(memories, assetInfo(asset))
          end
        end
      end
    end
    noctalia.log(`Immich Wallpaper: {#memories} memory photos today`)
    done()
  end)
end

local function refreshDaily(done)
  local today = os.date("%Y-%m-%d")
  if dailyKey == today then
    done()
    return
  end
  if dailyLoading then
    busySince = 0
    return
  end
  dailyLoading = true
  lookupFailed = false
  resolveNames(function()
    loadMemories(function()
      dailyLoading = false
      dailyKey = lookupFailed and "" or today
      done()
    end)
  end)
end

local function buildFilter(t)
  local filter = {
    type = { eq = "IMAGE" },
    visibility = { ["in"] = cfg("show_archived", false) and { "timeline", "archive" } or { "timeline" } },
  }

  local taken = {}
  local hasTaken = false
  local fromDate = dateSetting("images_from_date", false)
  local fromDays = tonumber(cfg("images_from_days", 0)) or 0
  if fromDate ~= nil then
    taken.gte = fromDate
    hasTaken = true
  elseif fromDays > 0 then
    taken.gte = isoDate(os.time() - fromDays * 24 * 60 * 60)
    hasTaken = true
  end
  local untilDate = dateSetting("images_until_date", true)
  if untilDate ~= nil then
    taken.lte = untilDate
    hasTaken = true
  end
  if hasTaken then
    filter.takenAt = taken
  end

  local rating = tonumber(cfg("rating", 0)) or 0
  if rating > 0 then
    filter.rating = { gte = rating }
  end

  local excluded = idsFor("album", excludedEntries())
  if #excluded > 0 then
    filter.albumIds = { none = excluded }
  end

  local branches = {}
  local albums = idsFor("album", t.albums)
  if #albums > 0 then
    table.insert(branches, { albumIds = { any = albums } })
  end
  local people = idsFor("person", t.people)
  if #people > 0 then
    table.insert(branches, { personIds = { any = people } })
  end
  local tags = idsFor("tag", t.tags)
  if #tags > 0 then
    table.insert(branches, { tagIds = { any = tags } })
  end
  if t.favorites then
    table.insert(branches, { isFavorite = { eq = true } })
  end
  if #branches > 0 then
    filter["or"] = branches
  end
  return filter
end

-- ---------------------------------------------------------------------------
-- Index (captions + the selection each folder was filled with)

local function indexPath()
  local dir = noctalia.pluginDataDir()
  if dir == nil then
    return nil
  end
  return `{dir}/{INDEX_FILE}`
end

local function saveIndex()
  local path = indexPath()
  if path == nil then
    return
  end
  -- Only keep captions for files that still exist in a target folder.
  local kept = {}
  for _, t in ipairs(targets) do
    for _, entry in ipairs(t.owned) do
      if photos[entry.path] ~= nil then
        kept[entry.path] = photos[entry.path]
      end
    end
  end
  photos = kept
  local encoded = noctalia.json.encode({ version = 3, selections = selections, photos = photos })
  if encoded ~= nil then
    noctalia.writeFile(path, encoded)
  end
end

local function loadIndex()
  local path = indexPath()
  if path == nil then
    return
  end
  local raw = noctalia.readFile(path)
  if type(raw) ~= "string" then
    return
  end
  local parsed = noctalia.json.decode(raw)
  if type(parsed) ~= "table" then
    return
  end
  if parsed.version == 3 then
    photos = type(parsed.photos) == "table" and parsed.photos or {}
    selections = type(parsed.selections) == "table" and parsed.selections or {}
  elseif type(parsed.photos) == "table" then
    legacyById = parsed.photos -- 0.2: { selection, photos = id -> info }
  else
    legacyById = parsed -- 0.1: id -> info
  end
end

-- ---------------------------------------------------------------------------
-- Folder sync
--
-- Files this plugin owns are named "<asset uuid>.<ext>". Anything else in a
-- folder is left alone, so it is safe to point at a shared folder.

local function scanTarget(t)
  t.owned = {}
  local names = noctalia.listDir(t.folder)
  if type(names) ~= "table" then
    return
  end
  for _, name in ipairs(names) do
    local id = name:match(UUID_FILE)
    if id ~= nil then
      local path = `{t.folder}/{name}`
      local info = noctalia.fileInfo(path)
      table.insert(t.owned, { id = id, path = path, mtime = (type(info) == "table" and info.mtime) or 0 })
      if photos[path] == nil and legacyById ~= nil and type(legacyById[id]) == "table" then
        local migrated = table.clone(legacyById[id])
        migrated.selection = nil
        photos[path] = migrated
      end
    end
  end
  table.sort(t.owned, function(a, b)
    return a.mtime < b.mtime
  end)
end

local function isOwned(t, id)
  for _, entry in ipairs(t.owned) do
    if entry.id == id then
      return true
    end
  end
  return false
end

-- Paths Noctalia is currently showing; never delete those.
local function inUse()
  local used = {}
  for _, output in ipairs(noctalia.outputs() or {}) do
    local p = noctalia.wallpaperPath(output.name)
    if type(p) == "string" and p ~= "" then
      used[noctalia.expandPath(p)] = true
    end
  end
  return used
end

local function removeOwned(t, index)
  local entry = t.owned[index]
  noctalia.removeFile(entry.path)
  photos[entry.path] = nil
  table.remove(t.owned, index)
end

local function evict(t)
  local target = tonumber(cfg("cache_size", 30)) or 30
  local used = inUse()
  local i = 1
  while #t.owned > target and i <= #t.owned do
    if used[t.owned[i].path] then
      i += 1
    else
      removeOwned(t, i)
    end
  end
end

-- Delete every photo saved for a target, except the ones on screen (those
-- are swapped out by replaceStale once the first new photo arrives).
local function purge(t)
  local used = inUse()
  local i = 1
  local removed = 0
  while i <= #t.owned do
    if used[t.owned[i].path] then
      i += 1
    else
      removeOwned(t, i)
      removed += 1
    end
  end
  noctalia.log(`Immich Wallpaper: selection for {t.folder} changed; removed {removed} photos, refilling`)
end

local function underFolder(path, folder)
  return path:sub(1, #folder + 1) == folder .. "/"
end

-- Noctalia's rotation only moves on when its own timer fires, so after a
-- selection change (or on first setup) a screen would keep showing an old
-- photo for up to a whole rotation interval. Swap such screens to newPath:
--   * a screen showing a photo saved in this folder for a different
--     selection gets the new photo, and the old file is deleted;
--   * on first fill of the only folder, a screen showing anything outside
--     the managed folders (e.g. Noctalia's bundled default) gets it too.
local function replaceStale(t, newPath, wasEmpty)
  local stale = {}
  for i, entry in ipairs(t.owned) do
    local info = photos[entry.path]
    if info == nil or info.selection ~= t.selection then
      stale[entry.path] = i
    end
  end

  local removed = {}
  for _, output in ipairs(noctalia.outputs() or {}) do
    local current = noctalia.wallpaperPath(output.name)
    current = (type(current) == "string" and current ~= "") and noctalia.expandPath(current) or ""
    local isStale = stale[current] ~= nil
    local outside = current == ""
    if not outside then
      outside = true
      for _, other in ipairs(targets) do
        if underFolder(current, other.folder) then
          outside = false
        end
      end
    end
    if isStale or (wasEmpty and #targets == 1 and outside) then
      noctalia.setWallpaper(output.name, newPath)
      noctalia.log(`Immich Wallpaper: {output.name} now shows {newPath}`)
      if isStale then
        removed[current] = true
      end
    end
  end

  local i = 1
  while i <= #t.owned do
    if removed[t.owned[i].path] then
      removeOwned(t, i)
    else
      i += 1
    end
  end
end

-- File type from the first bytes, limited to formats Noctalia can show
-- (HEIC/HEIF/AVIF need libheif on the host).
local HEIF_BRANDS = {
  heic = "heic", heix = "heic", hevc = "heic", hevx = "heic", heim = "heic", heis = "heic",
  mif1 = "heif", msf1 = "heif",
  avif = "avif", avis = "avif",
}

local function imageExtension(bytes)
  if bytes:sub(1, 3) == "\255\216\255" then
    return "jpg"
  end
  if bytes:sub(1, 4) == "RIFF" and bytes:sub(9, 12) == "WEBP" then
    return "webp"
  end
  if bytes:sub(1, 8) == "\137PNG\r\n\26\n" then
    return "png"
  end
  if bytes:sub(1, 2) == "\255\10" or bytes:sub(1, 12) == "\0\0\0\12JXL \13\10\135\10" then
    return "jxl"
  end
  if bytes:sub(1, 4) == "GIF8" then
    return "gif"
  end
  if bytes:sub(1, 2) == "BM" then
    return "bmp"
  end
  if bytes:sub(5, 8) == "ftyp" then
    return HEIF_BRANDS[bytes:sub(9, 12)]
  end
  return nil
end

-- Originals Noctalia can display directly; anything else (RAW, video,
-- huge files) is fetched as Immich's generated full-size image instead.
local DISPLAYABLE_ORIGINALS = {
  ["image/jpeg"] = true, ["image/png"] = true, ["image/webp"] = true,
  ["image/jxl"] = true, ["image/gif"] = true, ["image/bmp"] = true,
  ["image/heic"] = true, ["image/heif"] = true, ["image/avif"] = true,
}
local MAX_ORIGINAL_BYTES = 50 * 1024 * 1024

-- edited=true returns Immich's edited (cropped, rotated, mirrored) rendition
-- when there is one, and is ignored otherwise.
local function mediaPath(info)
  local size = cfg("image_size", "preview")
  if size == "original" and info.edited then
    -- The edited rendition is a JPEG whatever the original's format.
    return `/assets/{info.id}/original?edited=true`, true
  end
  if size == "original" then
    local mime = info.mime or ""
    local heif = mime == "image/heic" or mime == "image/heif" or mime == "image/avif"
    if
      DISPLAYABLE_ORIGINALS[mime]
      and (info.bytes or 0) <= MAX_ORIGINAL_BYTES
      and (not heif or cfg("heif_originals", false))
    then
      return `/assets/{info.id}/original?edited=true`, true
    end
    size = "fullsize"
  end
  if size ~= "fullsize" then
    return `/assets/{info.id}/thumbnail?size=preview&edited=true`, false
  end
  return `/assets/{info.id}/thumbnail?size=fullsize&edited=true`, true
end

-- Pixel size from the image header (JPEG, PNG, WebP), or nil. Reads only
-- headers, so it stays cheap inside the callback budget.
local function imageDimensions(bytes, ext)
  local b = string.byte
  if ext == "png" and #bytes >= 24 then
    local w = ((b(bytes, 17) * 256 + b(bytes, 18)) * 256 + b(bytes, 19)) * 256 + b(bytes, 20)
    local h = ((b(bytes, 21) * 256 + b(bytes, 22)) * 256 + b(bytes, 23)) * 256 + b(bytes, 24)
    return w, h
  end
  if ext == "webp" and #bytes >= 30 then
    local chunk = bytes:sub(13, 16)
    if chunk == "VP8X" then
      return 1 + b(bytes, 25) + b(bytes, 26) * 256 + b(bytes, 27) * 65536,
        1 + b(bytes, 28) + b(bytes, 29) * 256 + b(bytes, 30) * 65536
    elseif chunk == "VP8 " then
      return bit32.band(b(bytes, 27) + b(bytes, 28) * 256, 0x3FFF), bit32.band(b(bytes, 29) + b(bytes, 30) * 256, 0x3FFF)
    elseif chunk == "VP8L" then
      local b0, b1, b2, b3 = b(bytes, 22, 25)
      return 1 + b0 + bit32.band(b1, 0x3F) * 256,
        1 + bit32.rshift(b1, 6) + b2 * 4 + bit32.band(b3, 0x0F) * 1024
    end
    return nil
  end
  if ext == "jpg" then
    local i = 3
    local n = #bytes
    while i + 8 <= n do
      if b(bytes, i) ~= 0xFF then
        return nil
      end
      local marker = b(bytes, i + 1)
      if marker == 0xFF then
        i += 1 -- fill byte
      elseif marker >= 0xD0 and marker <= 0xD9 or marker == 0x01 then
        i += 2
      else
        if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
          return b(bytes, i + 7) * 256 + b(bytes, i + 8), b(bytes, i + 5) * 256 + b(bytes, i + 6)
        end
        i += 2 + b(bytes, i + 2) * 256 + b(bytes, i + 3)
      end
    end
  end
  return nil
end

-- True when a full-resolution request came back much smaller than the
-- original (Immich serves its preview when it has no full-size image).
local function isLowRes(info, bytes, ext)
  if info.w == nil or info.h == nil then
    return false
  end
  local w, h = imageDimensions(bytes, ext)
  if w == nil then
    return false
  end
  return math.max(w, h) < 0.9 * math.max(info.w, info.h)
end

-- One not-yet-saved photo from a small candidate list. With landscape-only
-- on, portrait photos are never taken.
local function choose(t, candidates)
  local landscapeOnly = cfg("landscape_only", true)
  for _, info in ipairs(candidates) do
    if not isOwned(t, info.id) and (not landscapeOnly or info.landscape) then
      return info
    end
  end
  return nil
end

-- Files that no longer fit the settings: portraits with landscape-only on,
-- and HEIC/HEIF/AVIF files when the host can't decode them (heif_originals
-- off). Ones on screen are marked stale instead, so replaceStale swaps them
-- out when the next photo arrives; otherwise they go once off screen.
local HEIF_EXTENSIONS = { heic = true, heif = true, avif = true }

local function unwantedReason(entry, info)
  if cfg("landscape_only", true) and info ~= nil and info.landscape == false then
    return "portrait"
  end
  if not cfg("heif_originals", false) then
    local ext = entry.path:match("%.(%a+)$")
    if ext ~= nil and HEIF_EXTENSIONS[ext:lower()] then
      return "HEIC/AVIF"
    end
  end
  return nil
end

local function dropUnwanted(t)
  local used = nil
  local removed = {}
  local i = 1
  while i <= #t.owned do
    local entry = t.owned[i]
    local info = photos[entry.path]
    local reason = unwantedReason(entry, info)
    if reason == nil then
      i += 1
    else
      used = used or inUse()
      if used[entry.path] then
        if info ~= nil then
          info.selection = nil
        end
        i += 1
      else
        removeOwned(t, i)
        removed[reason] = (removed[reason] or 0) + 1
      end
    end
  end
  for reason, n in pairs(removed) do
    noctalia.log(`Immich Wallpaper: {t.folder}: removed {n} {reason} photos`)
  end
end

-- Download `info` into t's folder. With `replace` (an entry of t.owned),
-- the photo is re-fetched in place instead of added.
local function download(t, info, replace)
  local base = serverUrl()
  local key = apiKey()
  local ok, err = noctalia.mkdirAll(t.folder)
  if not ok then
    busySince = 0
    t.misses += 1
    fail(`Could not create {t.folder}: {err or "?"}`)
    return
  end

  local path0, wantFull = mediaPath(info)
  local started = noctalia.http({
    url = `{base}/api{path0}`,
    method = "GET",
    headers = { `x-api-key: {key}`, "Accept: application/octet-stream" },
    follow_redirects = true,
  }, function(res)
    busySince = 0
    if not res.ok or res.status ~= 200 or type(res.body) ~= "string" then
      t.misses += 1
      fail(`Image {info.id}: HTTP {res.status} {excerpt(res.body)}`)
      return
    end
    local ext = imageExtension(res.body)
    if ext == nil then
      t.misses += 1
      fail(`Image {info.id}: not a format Noctalia can show ({info.mime or "?"})`)
      return
    end
    -- Write under a non-image name, then rename, so Noctalia's rotation
    -- never picks up a half-written file.
    local path = `{t.folder}/{info.id}.{ext}`
    local tmp = `{path}.part`
    local written, werr = noctalia.writeFile(tmp, res.body)
    if not written then
      fail(`Could not write {tmp}: {werr or "?"}`)
      return
    end
    local moved, merr = noctalia.renameFile(tmp, path)
    if not moved then
      noctalia.removeFile(tmp)
      fail(`Could not move {tmp}: {merr or "?"}`)
      return
    end
    local record = table.clone(info)
    record.selection = t.selection
    record.lowRes = wantFull and isLowRes(info, res.body, ext) or nil
    record.retryAt = record.lowRes and (os.time() + RETRY_SECONDS) or nil
    record.checkedAt = os.time()

    if replace ~= nil then
      if replace.path ~= path then
        noctalia.removeFile(replace.path)
        photos[replace.path] = nil
        replace.path = path
      end
      photos[path] = record
      saveIndex()
      noctalia.log(
        `Immich Wallpaper: re-fetched {path}{record.lowRes and " (still preview size; retrying hourly)" or " at full size"}`
      )
      return
    end

    local wasEmpty = #t.owned == 0
    photos[path] = record
    table.insert(t.owned, { id = info.id, path = path, mtime = os.time() })
    replaceStale(t, path, wasEmpty)
    evict(t)
    saveIndex()
    t.misses = 0
    setStatus("ready")
    noctalia.log(
      `Immich Wallpaper: saved {path} ({#t.owned} in folder){record.lowRes and "; preview size only, will retry" or ""}`
    )
  end)
  if not started then
    busySince = 0
  end
end

local function fetchFor(t)
  local key, keyErr = apiKey()
  if serverUrl() == "" or key == nil then
    if keyErr ~= nil then
      fail(keyErr)
    end
    setStatus("unconfigured")
    return
  end
  busySince = os.time()
  t.lastAttempt = busySince

  refreshDaily(function()
    -- Memories: the only source in memories-only mode, otherwise mixed in
    -- for roughly one photo in four.
    if t.memories and #memories > 0 and (memoriesOnly(t) or math.random() < 0.25) then
      local pick = choose(t, { memories[math.random(1, #memories)] })
      if pick ~= nil then
        download(t, pick)
        return
      end
    end
    if memoriesOnly(t) then
      busySince = 0
      t.misses += 1
      return
    end

    local filter = buildFilter(t)
    if hasSources(t) and filter["or"] == nil then
      -- Albums/people/tags are configured but none resolved: searching
      -- without them would silently use the whole library.
      busySince = 0
      t.misses += 1
      fail(`Nothing configured for {t.folder} was found in Immich`)
      return
    end
    local body = {
      size = SEARCH_SIZE,
      withExif = true,
      withPeople = true,
      filter = filter,
    }
    api("POST", "/search/random", body, nil, function(assets, err)
      if assets == nil then
        busySince = 0
        t.misses += 1
        fail(err)
        return
      end
      local candidates = {}
      for _, asset in ipairs(assets) do
        if acceptAsset(asset) then
          table.insert(candidates, assetInfo(asset))
        end
      end
      local pick = choose(t, candidates)
      if pick == nil then
        busySince = 0
        t.misses += 1
        if #assets == 0 then
          fail(`No photos matched the selection for {t.folder}`)
        elseif t.misses == 3 then
          noctalia.log(
            `Immich Wallpaper: {t.folder}: searches keep returning photos already saved; `
              .. `the selection probably has about {#t.owned} photos (fewer than {cfg("cache_size", 30)})`
          )
        end
        return
      end
      download(t, pick)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- Caption: publish details of whatever Noctalia is showing on the first
-- output (desktop widgets don't know which output they are on).

local function publishCurrent()
  local first = (noctalia.outputs() or {})[1]
  if first == nil then
    return
  end
  local path = noctalia.wallpaperPath(first.name)
  path = (type(path) == "string" and path ~= "") and noctalia.expandPath(path) or ""
  if path == lastCurrentPath then
    return
  end
  lastCurrentPath = path
  local info = photos[path]
  if info == nil then
    noctalia.state.set("current", {})
    return
  end
  noctalia.state.set("current", {
    path = path,
    date = info.date,
    location = info.location,
    people = info.people,
    description = info.description,
  })
end

-- With full size or original selected, upgrade photos that came back at
-- preview size (or were saved before sizes were recorded), one at a time,
-- skipping whatever is on screen. Returns true if it started a request.
local function retryLowRes(now)
  if cfg("image_size", "preview") == "preview" then
    return false
  end
  local used = nil
  for _, t in ipairs(targets) do
    for _, entry in ipairs(t.owned) do
      local rec = photos[entry.path]
      if rec ~= nil and (rec.lowRes or rec.w == nil) and (rec.retryAt or 0) <= now then
        used = used or inUse()
        if not used[entry.path] then
          rec.retryAt = now + RETRY_SECONDS -- set first, so failures don't loop
          busySince = now
          api("GET", `/assets/{entry.id}`, nil, MAX_MEMORY_BYTES, function(asset, err)
            if asset == nil or not acceptAsset(asset) then
              busySince = 0
              noctalia.log(`Immich Wallpaper: could not re-fetch {entry.id}: {err or "not an image"}`)
              return
            end
            download(t, assetInfo(asset), entry)
          end)
          return true
        end
      end
    end
  end
  return false
end

-- Re-download saved photos that were edited (or un-edited) in Immich since
-- they were saved, one at a time, skipping whatever is on screen. Each photo
-- is checked every EDIT_CHECK_SECONDS. Returns true if it started a request.
local function recheckEdits(now)
  local used = nil
  for _, t in ipairs(targets) do
    for _, entry in ipairs(t.owned) do
      local rec = photos[entry.path]
      if rec ~= nil and now - (rec.checkedAt or 0) >= EDIT_CHECK_SECONDS then
        used = used or inUse()
        if not used[entry.path] then
          rec.checkedAt = now -- set first, so failures don't loop
          busySince = now
          api("GET", `/assets/{entry.id}`, nil, MAX_MEMORY_BYTES, function(asset, err)
            if asset == nil or not acceptAsset(asset) then
              busySince = 0
              saveIndex()
              noctalia.log(`Immich Wallpaper: could not check {entry.id} for edits: {err or "not an image"}`)
              return
            end
            local info = assetInfo(asset)
            if info.edited ~= (rec.edited == true) or (info.edited and info.updatedAt ~= rec.updatedAt) then
              noctalia.log(`Immich Wallpaper: {entry.id} was {info.edited and "edited" or "un-edited"} in Immich; re-fetching`)
              download(t, info, entry)
              return
            end
            busySince = 0
            rec.updatedAt = info.updatedAt
            saveIndex()
          end)
          return true
        end
      end
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Main loop

function update()
  publishCurrent()

  local now = os.time()
  if busySince ~= 0 then
    if now - busySince <= BUSY_TIMEOUT then
      return
    end
    noctalia.log("Immich Wallpaper: request timed out or was aborted; retrying")
    busySince = 0
    dailyLoading = false
  end

  -- Portraits kept only because they were on screen go once they're not.
  for _, t in ipairs(targets) do
    dropUnwanted(t)
  end

  -- Round-robin over targets: fill each folder, then swap one photo per
  -- churn interval so every folder slowly walks through its selection.
  local size = tonumber(cfg("cache_size", 30)) or 30
  local churn = (tonumber(cfg("churn_minutes", 30)) or 30) * 60
  for k = 1, #targets do
    local index = (rr + k - 1) % #targets + 1
    local t = targets[index]
    -- A small selection keeps returning photos we have; back off.
    local backoff = math.min(5 * 2 ^ t.misses, 600)
    if now - t.lastAttempt >= backoff then
      local filling = #t.owned < size
      if filling or now - t.lastChurn >= churn then
        if not filling then
          t.lastChurn = now
        end
        rr = index
        fetchFor(t)
        return
      end
    end
  end

  if not retryLowRes(now) then
    recheckEdits(now)
  end
end

local function reset()
  dailyKey = ""
  dailyLoading = false
  busySince = 0
  lastCurrentPath = nil
  buildTargets()
  for _, t in ipairs(targets) do
    scanTarget(t)
    t.selection = selectionKey(t)
    local previous = selections[t.folder]
    if previous == nil then
      -- First time this plugin version sees the folder: adopt what is
      -- there as belonging to the current selection.
      for _, entry in ipairs(t.owned) do
        if photos[entry.path] ~= nil then
          photos[entry.path].selection = t.selection
        end
      end
    elseif previous ~= t.selection and #t.owned > 0 then
      purge(t)
    end
    selections[t.folder] = t.selection
    dropUnwanted(t)
    noctalia.log(`Immich Wallpaper: {t.folder}: {#t.owned} photos`)
  end
  legacyById = nil
  saveIndex()
  update()
end

function onConfigChanged()
  reset()
end

function onIpc(event, _payload)
  if event == "refresh" then
    reset()
  elseif event == "fetch" then
    for _, t in ipairs(targets) do
      t.lastAttempt = 0
      t.misses = 0
    end
    busySince = 0
    update()
  end
end

math.randomseed(os.time())
loadIndex()
reset()
