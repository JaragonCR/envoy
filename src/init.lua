local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local log = require("log")
local https = require("cosock.ssl.https")
local ltn12 = require("ltn12")
local json = require("st.json")

-- ==========================================================
-- Helper: HTTPS GET → parsed table or nil
-- ==========================================================
local function https_get(ip, path, token)
  local body = {}
  local _, code = https.request({
    url     = "https://" .. ip .. path,
    method  = "GET",
    sink    = ltn12.sink.table(body),
    headers = {
      ["Accept"]        = "application/json",
      ["Authorization"] = "Bearer " .. token
    },
    protocol = "any",
    verify   = "none"
  })

  if code ~= 200 then
    log.error("[ENVOY] HTTP GET " .. path .. " → " .. tostring(code))
    return nil
  end

  local ok, data = pcall(json.decode, table.concat(body))
  if not ok then
    log.error("[ENVOY] JSON parse failed for " .. path)
    return nil
  end

  return data
end

-- ==========================================================
-- Core Poll: /production.json (single call, all data)
-- ==========================================================
local function query_envoy(device)
  local ip = device.preferences.ipAddress
  local t1 = device.preferences.authToken1 or ""
  local t2 = device.preferences.authToken2 or ""
  local token = (t1 .. t2):match("^%s*(.-)%s*$")

  if not ip or ip == "" or token == "" then
    log.warn("[ENVOY] IP or token not set — skipping poll")
    return
  end

  log.debug("[ENVOY] Token length: " .. #token ..
            " (part1=" .. #t1 .. ", part2=" .. #t2 .. ")")

  local data = https_get(ip, "/production.json", token)
  if not data then return end

  -- --------------------------------------------------------
  -- PRODUCTION — use type=eim for accurate meter data
  -- --------------------------------------------------------
  local prod_w_now    = 0
  local prod_wh_today = 0
  local prod_wh_7day  = 0
  local prod_wh_life  = 0

  for _, entry in ipairs(data.production or {}) do
    if entry.type == "eim" then
      prod_w_now    = entry.wNow            or 0
      prod_wh_today = entry.whToday         or 0
      prod_wh_7day  = entry.whLastSevenDays or 0
      prod_wh_life  = entry.whLifetime      or 0
      break
    end
  end

  -- --------------------------------------------------------
  -- CONSUMPTION — total-consumption and net-consumption
  -- --------------------------------------------------------
  local cons_w_now    = 0
  local cons_wh_today = 0
  local net_w_now     = 0   -- positive = importing, negative = exporting

  for _, entry in ipairs(data.consumption or {}) do
    if entry.measurementType == "total-consumption" then
      cons_w_now    = entry.wNow    or 0
      cons_wh_today = entry.whToday or 0
    elseif entry.measurementType == "net-consumption" then
      net_w_now = entry.wNow or 0
    end
  end

  -- --------------------------------------------------------
  -- Grid direction: positive = importing, negative = exporting
  -- --------------------------------------------------------
  local grid_label = net_w_now >= 0 and "importing" or "exporting"

  log.info(string.format(
    "[ENVOY] Solar: %.0fW | Home: %.0fW | Grid: %.0fW (%s) | Solar today: %.2f kWh | Home today: %.2f kWh",
    prod_w_now, cons_w_now, math.abs(net_w_now), grid_label,
    prod_wh_today / 1000, cons_wh_today / 1000
  ))

  log.debug(string.format(
    "[ENVOY] 7-day: %.2f kWh | Lifetime: %.2f kWh",
    prod_wh_7day / 1000, prod_wh_life / 1000
  ))

  -- --------------------------------------------------------
  -- Emit to SmartThings
  -- --------------------------------------------------------

  -- Solar production (main tile)
  device:emit_event(capabilities.powerMeter.power({
    value = prod_w_now, unit = "W"
  }))
  device:emit_event(capabilities.energyMeter.energy({
    value = prod_wh_today / 1000, unit = "kWh"
  }))

  -- Home consumption via powerConsumptionReport
  -- (standard ST capability used by energy monitoring devices)
  local ok_cons = pcall(function()
    device:emit_event(capabilities.powerConsumptionReport.powerConsumption({
      energy          = math.floor(cons_wh_today),
      power           = math.floor(cons_w_now),
      deltaEnergy     = 0,
      persistedEnergy = 0,
      energySaved     = 0,
      powerSaved      = 0
    }))
  end)

  if not ok_cons then
    log.warn(string.format(
      "[ENVOY] Consumption (add powerConsumptionReport to profile): %.0fW now, %.2f kWh today",
      cons_w_now, cons_wh_today / 1000
    ))
  end

  log.debug(string.format(
    "[ENVOY] Grid: %.0fW %s | Home today: %.2f kWh",
    math.abs(net_w_now), grid_label, cons_wh_today / 1000
  ))
end

-- ==========================================================
-- Discovery Handler
-- ==========================================================
local function discovery_handler(driver, _, should_continue)
  if not should_continue() then return end

  log.info("[ENVOY] Discovery triggered. Creating Envoy device...")

  driver:try_create_device({
    type              = "LAN",
    device_network_id = "envoy-local-manual-1",
    label             = "Enphase Envoy",
    profile           = "envoy-local-power",
    manufacturer      = "Enphase",
    model             = "IQ Gateway",
    vendor_provided_label = "Envoy Solar Gateway"
  })
end

-- ==========================================================
-- Lifecycle Handlers
-- ==========================================================
local function device_init(driver, device)
  log.info("[ENVOY] Device initialized: " .. device.id)
  query_envoy(device)
  device.thread:call_on_schedule(300, function()
    query_envoy(device)
  end, "EnvoyPollingThread")
end

local function info_changed(driver, device, event, args)
  local old = args.old_st_store.preferences
  if old.ipAddress  ~= device.preferences.ipAddress  or
     old.authToken1 ~= device.preferences.authToken1 or
     old.authToken2 ~= device.preferences.authToken2 then
    log.info("[ENVOY] Preferences updated — triggering immediate poll")
    query_envoy(device)
  end
end

-- ==========================================================
-- Capability Handlers
-- ==========================================================
local function handle_refresh(driver, device, command)
  log.info("[ENVOY] Manual refresh triggered")
  query_envoy(device)
end

-- ==========================================================
-- Driver
-- ==========================================================
local envoy_driver = Driver("envoy-local", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init        = device_init,
    infoChanged = info_changed
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    }
  }
})

log.info("[ENVOY] Starting Envoy Local Edge Driver...")
envoy_driver:run()
