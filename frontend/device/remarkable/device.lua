local Generic = require("device/generic/device") -- <= look at this file!
local logger = require("logger")
local rapidjson = require("rapidjson")
local ffiutil = require("ffi/util")
local T = ffiutil.template
local _ = require("gettext")

local function yes() return true end
local function no() return false end

local Remarkable = Generic:new{
    model = "reMarkable",
    isRemarkable = yes,
    hasKeys = yes,
    hasOTAUpdates = yes,
    canReboot = yes,
    canPowerOff = yes,
    isTouchDevice = yes,
    hasFrontlight = no,
    display_dpi = 226,
    home_dir = "/mnt/root",
}

local EV_ABS = 3
local ABS_X = 00
local ABS_Y = 01
local ABS_MT_POSITION_X = 53
local ABS_MT_POSITION_Y = 54
-- Resolutions from libremarkable src/framebuffer/common.rs
local screen_width = 1404 -- unscaled_size_check: ignore
local screen_height = 1872 -- unscaled_size_check: ignore
local wacom_width = 15725 -- unscaled_size_check: ignore
local wacom_height = 20967 -- unscaled_size_check: ignore
local wacom_scale_x = screen_width / wacom_width
local wacom_scale_y = screen_height / wacom_height
local mt_width = 767 -- unscaled_size_check: ignore
local mt_height = 1023 -- unscaled_size_check: ignore
local mt_scale_x = screen_width / mt_width
local mt_scale_y = screen_height / mt_height
local adjustTouchEvt = function(self, ev)
    if ev.type == EV_ABS then
        -- Mirror X and scale up both X & Y as touch input is different res from
        -- display
        if ev.code == ABS_MT_POSITION_X then
            ev.value = (mt_width - ev.value) * mt_scale_x
        end
        if ev.code == ABS_MT_POSITION_Y then
            ev.value = (mt_height - ev.value) * mt_scale_y
        end
        -- The Wacom input layer is non-multi-touch and
        -- uses its own scaling factor.
        -- The X and Y coordinates are swapped, and the (real) Y
        -- coordinate has to be inverted.
        if ev.code == ABS_X then
            ev.code = ABS_Y
            ev.value = (wacom_height - ev.value) * wacom_scale_y
        elseif ev.code == ABS_Y then
            ev.code = ABS_X
            ev.value = ev.value * wacom_scale_x
        end
    end
end

function Remarkable:init()
    self.screen = require("ffi/framebuffer_mxcfb"):new{device = self, debug = logger.dbg}
    self.powerd = require("device/remarkable/powerd"):new{device = self}
    self.input = require("device/input"):new{
        device = self,
        event_map = require("device/remarkable/event_map"),
    }

    self.input.open("/dev/input/event0") -- Wacom
    self.input.open("/dev/input/event1") -- Touchscreen
    self.input.open("/dev/input/event2") -- Buttons
    self.input:registerEventAdjustHook(adjustTouchEvt)
    -- USB plug/unplug, battery charge/not charging are generated as fake events
    self.input.open("fake_events")

    local rotation_mode = self.screen.ORIENTATION_PORTRAIT
    self.screen.native_rotation_mode = rotation_mode
    self.screen.cur_rotation_mode = rotation_mode

    Generic.init(self)
end

function Remarkable:supportsScreensaver() return true end

function Remarkable:setDateTime(year, month, day, hour, min, sec)
    if hour == nil or min == nil then return true end
    local command
    if year and month and day then
        command = string.format("timedatectl set-time '%d-%d-%d %d:%d:%d'", year, month, day, hour, min, sec)
    else
        command = string.format("timedatectl set-time '%d:%d'",hour, min)
    end
    return os.execute(command) == 0
end

function Remarkable:intoScreenSaver()
    local Screensaver = require("ui/screensaver")
    if self.screen_saver_mode == false then
        Screensaver:show()
    end
    self.powerd:beforeSuspend()
    self.screen_saver_mode = true
end

function Remarkable:outofScreenSaver()
    if self.screen_saver_mode == true then
        local Screensaver = require("ui/screensaver")
        Screensaver:close()
    end
    self.powerd:afterResume()
    self.screen_saver_mode = false
end

function Remarkable:suspend()
    os.execute("systemctl suspend")
end

function Remarkable:resume()
end

function Remarkable:powerOff()
    os.execute("systemctl poweroff")
end

function Remarkable:reboot()
    os.execute("systemctl reboot")
end

local function osCapture(cmd, raw)
    local f = io.popen(cmd, 'r')
    if not f then
        return nil
    end
    local s = f:read('*a')
    f:close()
    if not s then
        return nil
    end
    if raw then
        return s
    end
    s = string.gsub(s, '^%s+', '')
    s = string.gsub(s, '%s+$', '')
    s = string.gsub(s, '[\n\r]+', ' ')
    return s
end

local function getNetworkProperty(path, name)
    path = string.sub(path, string.len("/codes/eeems/oxide1/") + 1)
    return rapidjson.decode(osCapture("rot --object Network:" .. path .. " wifi get " .. name))
end
local function getBSSProperty(path, name)
    path = string.sub(path, string.len("/codes/eeems/oxide1/") + 1)
    return rapidjson.decode(osCapture("rot --object BSS:" .. path .. " wifi get " .. name))
end
local function getWifiProperty(name)
    return rapidjson.decode(osCapture("rot wifi get " .. name))
end
local function isempty(s)
  return s == nil or s == ''
end

-- wireless
function Remarkable:initNetworkManager(NetworkMgr)
    if os.execute("which rot") == 1 then
        logger.info("Could not find rot")
        return
    end
    function NetworkMgr:turnOffWifi(complete_callback)
        logger.info("Remarkable: disabling Wi-Fi")
        os.execute("rot wifi call disable")
        if complete_callback then
            complete_callback()
        end
    end
    function NetworkMgr:turnOnWifi(complete_callback)
        logger.info("Remarkable: enabling Wi-Fi")
        os.execute("rot wifi call enable")
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        local info = InfoMessage:new{text = _("Connecting to Wi-Fi…")}
        UIManager:show(info)
        UIManager:nextTick(function()
            -- Wait for wifi to enable
            while getWifiProperty("state") < 1 do
                os.execute("sleep 1")
            end
            logger.info("Scanning for networks...")
            -- Initiate active scan
            os.execute("rot wifi call scan bool:true")
            -- Wait for scan to finish
            while getWifiProperty("scanning") do
                os.execute("sleep 1")
            end
            logger.info("Scan finished")
            -- Check for known networks
            local network_list, err = self:getNetworkList()
            while network_list == nil and not err do
                os.execute("sleep 1")
                network_list, err = self:getNetworkList()
            end
            if getWifiProperty("state") > 2 then
                local network = self:getCurrentNetwork()
                if network then
                    logger.info("Connected to " .. network.ssid)
                    UIManager:close(info)
                    local BD = require("ui/bidi")
                    UIManager:show(InfoMessage:new{
                       text = T(_("Connected to network %1"), BD.wrap(network.ssid)),
                       timeout = 3,
                    })
                    if complete_callback then
                        complete_callback()
                    end
                    return
                end
            end
            UIManager:close(info)
            UIManager:show(InfoMessage:new{
               text = _("No network found."),
               timeout = 3,
            })
            if complete_callback then
                complete_callback()
            end
            -- TODO
            --   In the future we will have to properly show the wifi menu
            --   But for now, oxide doesn't return enough information to properly
            --   use it.
            -- self:showNetworkMenu(complete_callback)
        end)
    end
    function NetworkMgr:getNetworkInterfaceName()
        return "wlan0"
    end
    function NetworkMgr:obtainIP()
        os.execute("dhcpcd")
    end
    function NetworkMgr:releaseIP()
        os.execute("dhcpcd -k")
    end
    function NetworkMgr:isWifiOn()
        return getWifiProperty("state") > 1
    end

    function NetworkMgr:getNetworkList()
        local currentNetwork = getWifiProperty("network")
        local bsss = getWifiProperty("bSSs")
        if not bsss then
            local err = "No network results."
            logger.err(err)
            return nil, err
        end
        local err = ""
        local results = nil
        for _, path in ipairs(bsss) do
            if path then
                local bssid = getBSSProperty(path, "bssid")
                -- We may need to wait for the object to have been registered properly
                while not bssid do
                    os.execute("sleep 1")
                    bssid = getBSSProperty(path, "bssid")
                end
                local ssid = getBSSProperty(path, "ssid")
                if not isempty(ssid) then
                    logger.info("Network " .. ssid)
                    local flags = ""
                    local keyMgmt = getBSSProperty(path, "key_mgmt")
                    if keyMgmt then
                        for _,flag in ipairs(keyMgmt) do
                            flags = flags .. "[" .. string.upper(flag) .. "]"
                        end
                    end
                    local network = {
                        bssid = bssid,
                        ssid = ssid,
                        frequency = getBSSProperty(path, "frequency"),
                        signal_level = getBSSProperty(path, "signal"),
                        flags = flags,
                        path = path,
                        connected = false
                    }
                    if network.signal then
                        network.signal_quality = math.min(math.max((network.signal + 100) * 2, 0), 100)
                    else
                        network.signal_quality = 0
                    end
                    local networkPath = getBSSProperty(path, "network")
                    if currentNetwork and currentNetwork ~= "/" and networkPath and networkPath == currentNetwork then
                        network.connected = true
                    end
                    if results == nil then
                        results = {}
                    end
                    table.insert(results, network)
                end
            else
                err = err .. "Got nil instead of dbus path. "
            end
        end
        if string.len(err) > 0 then
            logger.err("Error while getting networks: " .. err)
        end
        return results, err
    end
    function NetworkMgr:getCurrentNetwork()
        local path = getWifiProperty("network")
        if not path then
            logger.err("Unable to get current network")
            return nil
        end
        if path == "/" then
            return nil
        end
        return {
            ssid = getNetworkProperty(path, "ssid"),
        }
    end
    function NetworkMgr:authenticateNetwork(network)
        local InfoMessage = require("ui/widget/infomessage")
        local UIManager = require("ui/uimanager")
        local BD = require("ui/bidi")
        local info = InfoMessage:new{text = T(_("Connecting to %1."), BD.wrap(network.ssid)) }
        local properties = {
            ssid = network.ssid,
        }
        if network.psk then
            properties.key_mgmt = "WPA-PSK"
            properties.psk = network.password
        end
        local path, err = rapidjson.decode(osCapture("rot wifi call addNetwork 'QVariantMap:" .. rapidjson.encode(properties) .. "'"))
        local success = path and path ~= "/"
        UIManager:close(info)
        return success, err
    end
    function NetworkMgr:disconnectNetwork(network)
        os.execute("rot wifi call disconnect")
    end
end

return Remarkable

