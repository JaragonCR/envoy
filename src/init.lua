local Driver = require("st.driver")
local capabilities = require("st.capabilities")
local log = require("log")
local https = require("cosock.ssl.https") -- Swapped HTTP for HTTPS
local ltn12 = require("ltn12")
local json = require("st.json")

-- ==========================================================
-- Core Communication Logic
-- ==========================================================
local function query_envoy(device)
  local ip = device.preferences.ipAddress
  local token = device.preferences.authToken
  
  -- Prevent executing if preferences are missing
  if not ip or ip == "" or not token or token == "" then
    log.warn("Envoy IP address or Token not set in preferences. Skipping query.")
    return
  end
  
  -- Updated to HTTPS
  local url = "https://" .. ip .. "/api/v1/production"
  log.info("Querying Envoy at URL: " .. url)
  
  local response_body = {}
  
  -- Make the HTTPS GET request
  local success, code, headers, status = https.request({
    url = url,
    method = "GET",
    sink = ltn12.sink.table(response_body),
    headers = {
      ["Accept"] = "application/json",
      ["Authorization"] = "Bearer " .. token
    },
    -- Crucial for local devices: Ignores self-signed certificate errors
    protocol = "any",
    verify = "none" 
  })

  -- Check if the request was successful
  -- Note: success is nil if the network request fails entirely
  if type(code) ~= "number" or code ~= 200 then
    log.error("HTTPS Request Failed. HTTP Code: " .. tostring(code) .. " Status: " .. tostring(status))
    return
  end

  -- Combine the response chunks into a single string
  local response_string = table.concat(response_body)
  
  -- Parse the JSON safely
  local parsed_success, data = pcall(json.decode, response_string)
  
  if not parsed_success then
    log.error("Failed to parse JSON response from Envoy.")
    return
  end

  -- Extract data (based on standard Envoy /api/v1/production output)
  local current_power_watts = data.wattsNow
  local today_energy_wh = data.wattHoursToday

  if current_power_watts and today_energy_wh then
    -- Convert Watt-hours to Kilowatt-hours for the ST Energy capability
    local today_energy_kwh = today_energy_wh / 1000.0

    log.info("Envoy Data -> Power: " .. current_power_watts .. "W, Energy Today: " .. today_energy_kwh .. "kWh")

    -- Emit the events to SmartThings so the UI updates
    device:emit_event(capabilities.powerMeter.power({ value = current_power_watts, unit = "W" }))
    device:emit_event(capabilities.energyMeter.energy({ value = today_energy_kwh, unit = "kWh" }))
  else
    log.warn("JSON parsed successfully, but expected data fields ('wattsNow' or 'wattHoursToday') were missing.")
  end
end

-- ==========================================================
-- Discovery Handler
-- ==========================================================
local function discovery_handler(driver, _, should_continue)
  if not should_continue() then return end
  
  log.info("Discovery triggered. Creating manual Envoy device...")
  
  local device_metadata = {
    type = "LAN",
    device_network_id = "envoy-local-manual-1",
    label = "Enphase Envoy",
    profile = "envoy-local-power", -- Ensure this matches your .yml profile name exactly
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
  
  -- Start a polling loop to check the Envoy every 5 minutes (300 seconds)
  device.thread:call_on_schedule(300, function()
    query_envoy(device)
  end, "EnvoyPollingThread")
end

local function info_changed(driver, device, event, args)
  -- If either the IP or Token changed in settings, trigger an immediate refresh
  if args.old_st_store.preferences.ipAddress ~= device.preferences.ipAddress or 
     args.old_st_store.preferences.authToken ~= device.preferences.authToken then
    log.info("Preferences updated. Triggering new query.")
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
