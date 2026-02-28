local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local log = require("log")
local https = require("cosock.ssl.https")
local ltn12 = require("ltn12")
local json = require("st.json")

-- ==========================================================
-- Core Communication Logic
-- ==========================================================
local function query_envoy(device)
  local ip = device.preferences.ipAddress
  
  -- Concatenate split token, trimming any accidental whitespace
  local t1 = device.preferences.authToken1 or ""
  local t2 = device.preferences.authToken2 or ""
  local token = (t1 .. t2):match("^%s*(.-)%s*$")

  -- Prevent executing if preferences are missing
  if not ip or ip == "" or token == "" then
    log.warn("Envoy IP or Token not set in preferences. Skipping query.")
    return
  end

  log.debug("Token length: " .. #token .. " (part1=" .. #t1 .. ", part2=" .. #t2 .. ")")

  local url = "https://" .. ip .. "/api/v1/production"
  log.info("Querying Envoy at: " .. url)

  local response_body = {}

  local success, code, headers, status = https.request({
    url = url,
    method = "GET",
    sink = ltn12.sink.table(response_body),
    headers = {
      ["Accept"] = "application/json",
      ["Authorization"] = "Bearer " .. token
    },
    protocol = "any",
    verify = "none"
  })

  if type(code) ~= "number" or code ~= 200 then
    log.error("HTTPS Request Failed. Code: " .. tostring(code) .. " Status: " .. tostring(status))
    return
  end

  local response_string = table.concat(response_body)
  local parsed_success, data = pcall(json.decode, response_string)

  if not parsed_success then
    log.error("Failed to parse JSON response from Envoy.")
    log.debug("Raw body: " .. response_string)
    return
  end

  local current_power_watts = data.wattsNow
  local today_energy_wh = data.wattHoursToday

  if current_power_watts and today_energy_wh then
    local today_energy_kwh = today_energy_wh / 1000.0
    log.info("Poll OK -> Power: " .. current_power_watts .. "W, Energy: " .. today_energy_kwh .. "kWh")
    device:emit_event(capabilities.powerMeter.power({ value = current_power_watts, unit = "W" }))
    device:emit_event(capabilities.energyMeter.energy({ value = today_energy_kwh, unit = "kWh" }))
  else
    log.warn("JSON parsed OK but missing 'wattsNow' or 'wattHoursToday' fields.")
    log.debug("Raw body: " .. response_string)
  end
end

-- ==========================================================
-- Discovery Handler
-- ==========================================================
local function discovery_handler(driver, _, should_continue)
  if not should_continue() then return end

  log.info("Discovery triggered. Creating Envoy device...")

  local device_metadata = {
    type = "LAN",
    device_network_id = "envoy-local-manual-1",
    label = "Enphase Envoy",
    profile = "envoy-local-power",
    manufacturer = "Enphase",
    model = "Envoy Local",
    vendor_provided_label = "Envoy Solar Gateway"
  }

  driver:try_create_device(device_metadata)
end

-- ==========================================================
-- Lifecycle Handlers
-- ==========================================================
local function device_init(driver, device)
  log.info("Envoy device initialized: " .. device.id)
  device.thread:call_on_schedule(300, function()
    query_envoy(device)
  end, "EnvoyPollingThread")
end

local function info_changed(driver, device, event, args)
  if args.old_st_store.preferences.ipAddress ~= device.preferences.ipAddress or
     args.old_st_store.preferences.authToken1 ~= device.preferences.authToken1 or
     args.old_st_store.preferences.authToken2 ~= device.preferences.authToken2 then
    log.info("Preferences updated. Triggering immediate query.")
    query_envoy(device)
  end
end

-- ==========================================================
-- Capability Handlers
-- ==========================================================
local function handle_refresh(driver, device, command)
  log.info("Manual refresh triggered.")
  query_envoy(device)
end

-- ==========================================================
-- Driver Initialization
-- ==========================================================
local envoy_driver = Driver("envoy-local", {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    infoChanged = info_changed
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    }
  }
})

log.info("Starting Envoy Local Edge Driver...")
envoy_driver:run()
