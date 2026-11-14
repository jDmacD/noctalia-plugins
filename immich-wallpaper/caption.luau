--!nonstrict
-- Desktop / lock screen widget: the current wallpaper photo's date, place,
-- people and description, ImmichFrame-style. A pure view over the service's
-- "current" state.

local function cfg(key, fallback)
  local v = noctalia.getConfig(key)
  if v == nil then
    return fallback
  end
  return v
end

local function nonEmpty(s)
  return type(s) == "string" and s ~= ""
end

local function render()
  local current = noctalia.state.get("current")
  local width = tonumber(cfg("max_width", 360)) or 360
  local rows = {}

  if type(current) == "table" then
    if cfg("show_photo_date", true) and nonEmpty(current.date) then
      table.insert(rows, ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "calendar", size = 14, color = "on_surface_variant" }),
        ui.label({ text = current.date, fontSize = 14, fontWeight = "medium", maxWidth = width }),
      }))
    end
    if cfg("show_image_location", true) and nonEmpty(current.location) then
      table.insert(rows, ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "map-pin", size = 14, color = "on_surface_variant" }),
        ui.label({ text = current.location, fontSize = 13, maxWidth = width, maxLines = 2 }),
      }))
    end
    if cfg("show_people_desc", true) and nonEmpty(current.people) then
      table.insert(rows, ui.row({ gap = 6, align = "center" }, {
        ui.glyph({ name = "users", size = 14, color = "on_surface_variant" }),
        ui.label({ text = current.people, fontSize = 13, maxWidth = width, maxLines = 2 }),
      }))
    end
    if cfg("show_image_desc", true) and nonEmpty(current.description) then
      table.insert(rows, ui.label({ text = current.description, fontSize = 12, opacity = 0.8, maxWidth = width, maxLines = 4 }))
    end
  end

  if #rows == 0 then
    -- Nothing to say about this photo (or nothing applied yet): render an
    -- empty, transparent node rather than an empty card.
    desktopWidget.render(ui.column({}, {}))
    return
  end

  desktopWidget.render(ui.column({ gap = 4, padding = 10, radius = 10, fill = "surface/0.55" }, rows))
end

noctalia.state.watch("current", render)
render()
