-- settings/zen_updater.lua
-- Checks the GitHub releases API for a newer Zen UI version, downloads the
-- release.zip asset, unpacks it in-place, and prompts for a KOReader restart.

local _ = require("gettext")
local json = require("json")
local logger = require("logger")

local GITHUB_RELEASES_URL = "https://api.github.com/repos/AnthonyGress/zen_ui.koplugin/releases"

-- Resolve the plugin root directory from this file's own path so the module
-- works regardless of where KOReader is installed.
local PLUGIN_ROOT = require("common/plugin_root")

local M = {}

-- Cached result (populated on first check_for_update call).
M._checked          = false
M._has_update       = false
M._latest_ver       = nil   -- latest version string without leading "v"
M._dl_url           = nil   -- download URL for release.zip
M._banner_loaded    = false -- true after init_banner() has run
M._wakeup_timer     = nil   -- pending UIManager scheduled function (for unschedule)
M._check_cancelled  = false -- set to true by cancel_wakeup_check to abort mid-poll
M._on_update_found  = nil   -- optional callback fired when background check detects a new update

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Parse major/minor/patch integers from version strings like "v1.2.3",
--- "1.2.3", or "1.2.3-beta1". Returns nums + a boolean for pre-release and
--- the trailing integer from the pre-release label (e.g. 3 for "beta3") so
--- that "1.2.1-beta3" compares greater than "1.2.1-beta2".
local function parse_semver(v)
    v = (v or ""):match("^v?(.+)$") or ""
    local base = v:match("^([%d%.]+)") or ""
    local pre_str = v:match("^[%d%.]+[-+](.+)$") or ""
    local is_pre = pre_str ~= ""
    local pre_num = tonumber(pre_str:match("(%d+)$")) or 0
    local maj, min, pat = base:match("^(%d+)%.(%d+)%.?(%d*)$")
    return tonumber(maj) or 0, tonumber(min) or 0, tonumber(pat) or 0, is_pre, pre_num
end

--- Returns true when a's M.m.p base is strictly greater than b's (ignores pre-release label).
--- Used for channel selection: prefer stable when base versions are equal (graduation path).
local function semver_base_gt(a, b)
    local a1, a2, a3 = parse_semver(a)
    local b1, b2, b3 = parse_semver(b)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    return a3 > b3
end

--- Returns true when version string a is strictly greater than b.
--- Stable "1.2.3" > pre-release "1.2.3-beta1" per semver precedence rules.
--- Among pre-releases with the same base, compares trailing number (beta3 > beta2).
local function semver_gt(a, b)
    local a1, a2, a3, a_pre, a_pn = parse_semver(a)
    local b1, b2, b3, b_pre, b_pn = parse_semver(b)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    if a3 ~= b3 then return a3 > b3 end
    -- same numbers: stable beats pre-release
    if a_pre ~= b_pre then return not a_pre end
    -- both pre-release: compare trailing number (e.g. beta3 > beta2)
    if a_pre then return a_pn > b_pn end
    return false
end

--- Read the current plugin version from _meta.lua.
local function get_current_version()
    local ok, meta = pcall(dofile, PLUGIN_ROOT .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "0.0.0"
end

--- Get the zen_ui.koplugin.zip download URL from a decoded release object.
local function get_asset_url(release)
    if not release or type(release.assets) ~= "table" then return nil end
    for _i, asset in ipairs(release.assets) do
        if asset.name == "zen_ui.koplugin.zip" then
            return asset.browser_download_url
        end
    end
end

--- Decode a releases list JSON body and return stable/beta tag+url.
local function parse_release_list(body)
    local ok, releases = pcall(json.decode, body)
    if not ok or type(releases) ~= "table" then
        logger.warn("ZenUpdater: JSON decode failed")
        return nil
    end
    local stable_tag, stable_url, beta_tag, beta_url
    for _i, release in ipairs(releases) do
        if not stable_tag and not release.prerelease then
            stable_tag = release.tag_name
            stable_url = get_asset_url(release)
        end
        if not beta_tag and release.prerelease then
            beta_tag = release.tag_name
            beta_url = get_asset_url(release)
        end
        if stable_tag and beta_tag then break end
    end
    return stable_tag, stable_url, beta_tag, beta_url
end

--- Best-effort HTTPS GET; returns the response body string or nil.
--- Uses ssl.https (LuaSec, bundled with KOReader). Blocking -- use only
--- for user-initiated checks.
local function https_get(url)
    local ok_ssl, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_ssl or not ok_ltn then
        logger.warn("ZenUpdater: ssl.https or ltn12 not available")
        return nil
    end

    logger.dbg("ZenUpdater: GET", url)
    local body = {}
    local ok_req, req_err = pcall(function()
        local _, code = https.request{
            url     = url,
            headers = { ["User-Agent"] = "zen_ui.koplugin" },
            sink    = ltn12.sink.table(body),
        }
        -- code can be a string error message on Kobo (e.g. "connection refused")
        if code ~= 200 then
            logger.warn("ZenUpdater: https_get non-200:", tostring(code))
            body = nil
        end
    end)
    if not ok_req then
        logger.warn("ZenUpdater: https_get error:", req_err)
        return nil
    end
    if not body then return nil end
    return table.concat(body)
end

--- Returns true only for a proper release asset download URL.
local function is_valid_asset_url(url)
    return type(url) == "string" and url:find("/releases/download/", 1, true) ~= nil
end

--- Download a file via HTTPS to dest_path, following up to 5 redirects.
--- Returns true on success, or false + error message on failure.
local function https_download(url, dest_path, depth)
    depth = depth or 0
    if depth > 5 then return false, "too many redirects" end

    local ok_ssl, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_ssl or not ok_ltn then
        return false, "ssl.https not available"
    end

    -- Resolve any redirect chain via HEAD requests (avoids writing partial data).
    local resolved_url = url
    for _ = 1, 5 do
        local _, r_code, r_headers = https.request{
            url     = resolved_url,
            method  = "HEAD",
            headers = { ["User-Agent"] = "zen_ui.koplugin" },
            sink    = ltn12.sink.null(),
        }
        if (r_code == 301 or r_code == 302 or r_code == 307 or r_code == 308)
            and r_headers and r_headers.location then
            resolved_url = r_headers.location
        else
            break
        end
    end

    -- Perform the actual download.
    local f, ferr = io.open(dest_path, "wb")
    if not f then return false, ferr end

    local _, dl_code = https.request{
        url     = resolved_url,
        headers = { ["User-Agent"] = "zen_ui.koplugin" },
        sink    = ltn12.sink.file(f),
    }
    -- ltn12.sink.file closes f on EOF; pcall guards against double-close.
    pcall(f.close, f)

    if dl_code ~= 200 then
        os.remove(dest_path)
        return false, "HTTP " .. tostring(dl_code)
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local CHECK_INTERVAL        = 24 * 3600  -- seconds between automatic checks
local NET_SETTLE_DELAY      = 15         -- seconds after resume before first network attempt
local NET_RETRY_DELAY       = 2 * 60    -- seconds to wait before retrying when no network
local NET_ERROR_BASE_DELAY  = 30         -- first retry delay (s) after API failure; doubles each retry
local NET_ERROR_MAX_RETRIES = 2          -- max error retries: 30s, 60s
local INSTALL_TIMEOUT       = 120        -- max seconds for download + apply
local GS_KEY_TIME    = "zen_ui_last_update_check"
local GS_KEY_AVAIL   = "zen_ui_update_available"
local GS_KEY_VER     = "zen_ui_latest_version"
local GS_KEY_URL     = "zen_ui_update_dl_url"
local GS_KEY_CHANNEL = "zen_ui_update_channel"

--- Load or write persisted update state via G_reader_settings.
local function get_gs()
    local ok, gs = pcall(function() return G_reader_settings end)
    return (ok and gs) or nil
end

--- Returns true when the 24h check interval has elapsed since the last check.
local function is_check_due()
    local gs  = get_gs()
    local now = os.time()
    local last = gs and gs:readSetting(GS_KEY_TIME) or 0
    local last_num = type(last) == "number" and last or 0
    local delta = now - last_num
    local due = delta >= CHECK_INTERVAL
    logger.info("ZenUpdater: is_check_due last=", last_num, "now=", now, "delta=", delta, "due=", tostring(due))
    return due
end

local function get_channel()
    local gs = get_gs()
    if gs then
        local ch = gs:readSetting(GS_KEY_CHANNEL)
        if ch == "beta" then return "beta" end
    end
    return "stable"
end

local function persist_state(now)
    local gs = get_gs()
    if not gs then return end
    gs:saveSetting(GS_KEY_TIME,  now)
    gs:saveSetting(GS_KEY_AVAIL, M._has_update)
    gs:saveSetting(GS_KEY_VER,   M._latest_ver or "")
    gs:saveSetting(GS_KEY_URL,   M._dl_url or "")
    pcall(gs.flush, gs)
end

--- Clear all persisted update state (called after a successful install).
local function clear_update_state()
    M._has_update = false
    M._latest_ver = nil
    M._dl_url     = nil
    local gs = get_gs()
    if gs then
        gs:saveSetting(GS_KEY_AVAIL, false)
        gs:saveSetting(GS_KEY_VER,   "")
        gs:saveSetting(GS_KEY_URL,   "")
        pcall(gs.flush, gs)
    end
end

local function load_cached_state()
    local gs = get_gs()
    if not gs then return end
    M._has_update = gs:readSetting(GS_KEY_AVAIL) == true
    local ver = gs:readSetting(GS_KEY_VER)
    M._latest_ver = (type(ver) == "string" and ver ~= "") and ver or nil
    local url = gs:readSetting(GS_KEY_URL)
    -- Reject stale zipball/tarball URLs from before the asset-only fix.
    M._dl_url = is_valid_asset_url(url) and url or nil
    -- Discard stale notifications when the installed version already matches
    -- or exceeds the cached release (e.g. after a successful update).
    if M._has_update and not semver_gt(M._latest_ver or "", get_current_version()) then
        clear_update_state()
    end
end

--- Perform an actual network check; returns true on success.
local function do_network_check()
    local channel = get_channel()
    local current = get_current_version()
    logger.dbg("ZenUpdater: do_network_check channel=", channel, "current=", current)

    local body = https_get(GITHUB_RELEASES_URL .. "?per_page=10")
    if not body then
        logger.warn("ZenUpdater: no response from releases API")
        return false
    end

    local stable_tag, stable_url, beta_tag, beta_url = parse_release_list(body)
    logger.dbg("ZenUpdater: stable=", stable_tag, "beta=", beta_tag)

    local tag, dl_url
    -- On beta channel: use beta only when its base version (M.m.p) is strictly newer
    -- than stable's. If stable has the same or newer base, prefer stable (graduation path).
    if channel == "beta" and beta_tag and semver_base_gt(beta_tag, stable_tag or "0.0.0") then
        tag    = beta_tag
        dl_url = beta_url
    elseif stable_tag then
        tag    = stable_tag
        dl_url = stable_url
    else
        tag    = beta_tag
        dl_url = beta_url
    end

    if not tag then
        logger.warn("ZenUpdater: no tag found in API response")
        return false
    end
    M._latest_ver = tag:match("^v?(.+)$") or tag
    M._dl_url     = dl_url
    M._has_update = semver_gt(tag, current)
    logger.dbg("ZenUpdater: latest=", M._latest_ver, "has_update=", tostring(M._has_update))
    return true
end

--- Run do_network_check() in a non-blocking subprocess via Trapper.
--- setup_fn(_co) -- optional; called with the coroutine so the caller can wire
---                   a cancel button via coroutine.resume(_co, false).
--- on_done(net_ok) -- called when the subprocess completes.
--- on_cancelled()  -- called when dismissed before completion; may be nil.
local function network_check_async(trap_widget, setup_fn, on_done, on_cancelled)
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local _co = coroutine.running()
        if setup_fn then setup_fn(_co) end
        local completed, net_ok, has_upd, latest_ver, dl_url =
            Trapper:dismissableRunInSubprocess(function()
                local ok = do_network_check()
                return ok, M._has_update, M._latest_ver, M._dl_url
            end, trap_widget)
        if completed and net_ok then
            M._has_update = has_upd
            M._latest_ver = latest_ver
            M._dl_url     = dl_url
        end
        if not completed then
            if on_cancelled then on_cancelled() end
        else
            on_done(net_ok)
        end
    end)
end

--- Load persisted banner state once per session; never makes network calls.
--- Called from zen_settings.lua so the update banner appears from cached data.
function M.init_banner()
    if M._banner_loaded then return end
    M._banner_loaded = true
    load_cached_state()
end

--- Cancel any pending background wakeup check.
function M.cancel_wakeup_check()
    M._check_cancelled = true
    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if ok_um and UIManager and M._wakeup_timer then
        UIManager:unschedule(M._wakeup_timer)
    end
    M._wakeup_timer = nil
    logger.dbg("ZenUpdater: wakeup check cancelled")
end

--- Schedule a background update check on device resume.
--- Waits NET_SETTLE_DELAY seconds for the network to reconnect, then runs a
--- blocking HTTPS check inside a UIManager timer (not on the resume handler itself).
--- If no network, retries once after NET_RETRY_DELAY, then gives up.
--- If network is up but the API call fails, retries with exponential backoff
--- (NET_ERROR_BASE_DELAY doubling each attempt, up to NET_ERROR_MAX_RETRIES).
--- Cancelled on suspend so nothing fires while asleep.
function M.schedule_wakeup_check()
    logger.info("ZenUpdater: schedule_wakeup_check called")
    M.cancel_wakeup_check()  -- reset on every resume
    M._check_cancelled = false
    if not is_check_due() then
        logger.info("ZenUpdater: background check skipped, within 24h window")
        return
    end

    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if not ok_um or not UIManager then
        logger.warn("ZenUpdater: UIManager not available, aborting")
        return
    end

    local function has_network()
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        return ok_nm and NetworkMgr and NetworkMgr:isWifiOn()
    end

    -- Run the network check; on failure retry with exponential backoff.
    -- Uses a subprocess so the UI thread is never blocked.
    local function run_check_with_retry(retry_count, error_delay)
        if M._check_cancelled then return end
        logger.info("ZenUpdater: starting background network check")
        network_check_async(
            nil,  -- invisible trap: taps pass through normally
            nil,
            function(net_ok)
                if M._check_cancelled then return end
                if net_ok then
                    persist_state(os.time())
                    M._banner_loaded = true
                    logger.info("ZenUpdater: background check done, has_update=", tostring(M._has_update))
                    if M._has_update and type(M._on_update_found) == "function" then
                        M._on_update_found()
                    end
                elseif retry_count < NET_ERROR_MAX_RETRIES then
                    logger.warn("ZenUpdater: check failed, retry", retry_count + 1, "of", NET_ERROR_MAX_RETRIES, "in", error_delay, "s")
                    local next_count = retry_count + 1
                    local next_delay = error_delay * 2
                    local function error_retry()
                        M._wakeup_timer = nil
                        run_check_with_retry(next_count, next_delay)
                    end
                    M._wakeup_timer = error_retry
                    UIManager:scheduleIn(error_delay, error_retry)
                else
                    logger.warn("ZenUpdater: background check failed after", NET_ERROR_MAX_RETRIES, "retries, giving up")
                end
            end
        )
    end

    -- Deferred so the HTTPS call never blocks the onResume/init handler directly.
    local function attempt()
        M._wakeup_timer = nil
        if M._check_cancelled then return end
        local net_up = has_network()
        logger.info("ZenUpdater: attempt fired, network=", tostring(net_up))
        if not net_up then
            -- No network after settle delay -- retry once after NET_RETRY_DELAY.
            logger.info("ZenUpdater: no network, scheduling retry in ", NET_RETRY_DELAY, "s")
            local function retry_check()
                M._wakeup_timer = nil
                if M._check_cancelled then return end
                local retry_net = has_network()
                logger.info("ZenUpdater: retry fired, network=", tostring(retry_net))
                if not retry_net then
                    logger.info("ZenUpdater: retry: still no network, giving up")
                    return
                end
                run_check_with_retry(0, NET_ERROR_BASE_DELAY)
            end
            M._wakeup_timer = retry_check
            UIManager:scheduleIn(NET_RETRY_DELAY, retry_check)
            return
        end
        run_check_with_retry(0, NET_ERROR_BASE_DELAY)
    end

    M._wakeup_timer = attempt
    UIManager:scheduleIn(NET_SETTLE_DELAY, attempt)
    logger.info("ZenUpdater: wakeup check scheduled in ", NET_SETTLE_DELAY, "s")
end

--- Check for updates at most once every 24 h (throttled via G_reader_settings).
--- Returns "ok" (live check succeeded), "error" (network failure), or "cached" (throttled).
function M.check_for_update()
    if M._checked then
        logger.dbg("ZenUpdater: already checked this session, skipping")
        return "cached"
    end
    M._checked = true

    local gs  = get_gs()
    local now = os.time()
    local last = gs and gs:readSetting(GS_KEY_TIME) or 0
    logger.dbg("ZenUpdater: check_for_update now=", now, "last=", last, "interval=", CHECK_INTERVAL)

    if type(last) == "number" and (now - last) < CHECK_INTERVAL then
        logger.dbg("ZenUpdater: within throttle window, loading cached state")
        load_cached_state()
        logger.dbg("ZenUpdater: cached has_update=", tostring(M._has_update), "latest=", tostring(M._latest_ver))
        return "cached"
    end

    -- Attempt a live check; if it fails, fall back to cached state.
    if not do_network_check() then
        logger.warn("ZenUpdater: live check failed, loading cached state")
        load_cached_state()
        return "error"
    end

    persist_state(now)
    return "ok"
end

--- Returns true when a newer release has been detected.
function M.has_update()
    return M._has_update == true
end

--- Returns the latest release version string (without leading "v"), or nil.
function M.latest_version()
    return M._latest_ver
end

--- Download, unpack, and reboot using an existing ZenScreen for all UI feedback.
local function _do_install(screen, plugin_root, plugins_dir)
    local UIManager = require("ui/uimanager")
    local Trapper   = require("ui/trapper")
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")

    local function has_network()
        return ok_nm and NetworkMgr and NetworkMgr:isWifiOn()
    end

    if not is_valid_asset_url(M._dl_url) then
        do_network_check()
    end
    if not is_valid_asset_url(M._dl_url) then
        screen:update{ subtitle = _("No update asset found."), button = _("OK"), dismissable = true }
        return
    end

    if not has_network() then
        screen:update{ subtitle = _("Update failed: network connection lost."), button = _("OK"), dismissable = true }
        return
    end

    local zip_path = plugins_dir .. "/zen_ui_update.zip"

    -- Trapper:wrap() runs the function as a coroutine so UIManager stays alive.
    Trapper:wrap(function()
        local _co = coroutine.running()
        local timed_out = false
        local cancelled = false

        -- Show Cancel button now that _co is available to receive the abort signal.
        -- Passing screen as trap_widget keeps ZenScreen on top (no invisible TrapWidget
        -- is stacked above it), so taps reach _on_button_action normally.
        screen._on_button_action = function()
            cancelled = true
            coroutine.resume(_co, false)
        end
        screen:update{ button = _("Cancel"), later_button = false, dismissable = false }
        UIManager:forceRePaint()

        local timeout_cb = function()
            timed_out = true
            coroutine.resume(_co, false)
        end
        UIManager:scheduleIn(INSTALL_TIMEOUT, timeout_cb)

        local completed, ok, err = Trapper:dismissableRunInSubprocess(function()
            return https_download(M._dl_url, zip_path)
        end, screen)

        UIManager:unschedule(timeout_cb)
        screen._on_button_action = nil  -- prevent stale cancel action on subsequent button states

        if not completed then
            os.remove(zip_path)
            if cancelled then
                screen:onClose()
            elseif timed_out then
                screen:update{ subtitle = _("Update failed: timed out."), button = _("OK"), dismissable = true }
            elseif not has_network() then
                screen:update{ subtitle = _("Update failed: network connection lost."), button = _("OK"), dismissable = true }
            else
                screen:update{ subtitle = _("Update cancelled."), button = _("OK"), dismissable = true }
            end
            return
        end

        if not ok then
            if not has_network() then
                screen:update{ subtitle = _("Update failed: network connection lost."), button = _("OK"), dismissable = true }
            else
                screen:update{ subtitle = _("Download failed: ") .. (err or _("unknown error")), button = _("OK"), dismissable = true }
            end
            return
        end

        screen:update{ subtitle = _("Installing…"), button = false }
        UIManager:forceRePaint()

        local rm_rc = os.execute(string.format("rm -rf %q", plugin_root))
        if rm_rc ~= 0 and rm_rc ~= true then
            os.remove(zip_path)
            screen:update{ subtitle = _("Failed to remove existing plugin."), button = _("OK"), dismissable = true }
            return
        end

        local unzip_rc = os.execute(string.format("unzip -q %q -d %q", zip_path, plugins_dir))
        os.remove(zip_path)
        if unzip_rc ~= 0 and unzip_rc ~= true then
            screen:update{ subtitle = _("Failed to unpack update."), button = _("OK"), dismissable = true }
            return
        end

        clear_update_state()
        local gs2 = get_gs()
        if gs2 then
            gs2:saveSetting("zen_ui_just_updated", M._latest_ver or "")
            pcall(gs2.flush, gs2)
        end

        screen:update{ subtitle = _("Rebooting…"), button = false }
        UIManager:forceRePaint()
        UIManager:scheduleIn(1, function()
            UIManager:broadcastEvent(require("ui/event"):new("Restart"))
        end)
    end)
end

--- Show the ZenScreen update UI for a known-available update and run the install.
--- Called from both the settings banner and the About > Check for updates item.
local function _show_update_screen_and_install(plugin)
    local UIManager = require("ui/uimanager")
    local ZenScreen = require("common/zen_screen")

    local plugin_root = PLUGIN_ROOT
        or (plugin and type(plugin.path) == "string" and plugin.path ~= "" and plugin.path)
        or ""
    local plugins_dir = plugin_root:match("^(.*)/[^/]+$") or plugin_root
    local ver_label   = M._latest_ver and ("v" .. M._latest_ver) or _("latest")

    local screen
    screen = ZenScreen:new{
        subtitle     = _("Update available: ") .. ver_label,
        button       = _("Update now"),
        later_button = _("Later"),
        dismissable  = true,
    }
    screen._on_button_action = function()
        screen:update{ subtitle = _("Downloading…"), button = false, later_button = false, dismissable = false }
        UIManager:forceRePaint()
        UIManager:scheduleIn(0.1, function()
            _do_install(screen, plugin_root, plugins_dir)
        end)
    end
    UIManager:show(screen)
end

--- Download the latest release.zip, unpack it over the plugin directory, and
--- prompt the user to restart KOReader.
function M.run_update(plugin)
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and not NetworkMgr:isWifiOn() then
        NetworkMgr:runWhenOnline(function() _show_update_screen_and_install(plugin) end)
    else
        _show_update_screen_and_install(plugin)
    end
end

--- Returns a menu item for the top of the Zen UI settings page when an update
--- is available, or nil when no update has been detected.
function M.build_update_available_item(plugin)
    if not M._has_update then return nil end
    local ver_label = M._latest_ver and ("v" .. M._latest_ver) or _("latest")
    return {
        _zen_update_banner = true,  -- marker so root_items.callback can remove it
        text          = "\u{F01B} " .. _("Update available: ") .. ver_label,
        keep_menu_open = true,
        callback      = function()
            M.run_update(plugin)
        end,
    }
end

--- Returns the "Check for updates" menu item for the About section.
--- When a newer version has already been detected the text changes to reflect
--- the pending update and tapping it launches the download flow directly.
function M.build_update_now_item(plugin)
    return {
        text_func = function()
            if M._has_update then
                local ver_label = M._latest_ver and ("v" .. M._latest_ver) or _("latest")
                return "\u{F01B} " .. _("Update available: ") .. ver_label
            end
            return _("Check for updates")
        end,
        keep_menu_open = true,
        callback = function()
            local UIManager  = require("ui/uimanager")
            local ZenScreen  = require("common/zen_screen")
            local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")

            -- Reset throttle so this check always goes to the network.
            M._checked    = false
            M._has_update = false
            M._latest_ver = nil
            M._dl_url     = nil
            local gs = get_gs()
            if gs then
                gs:saveSetting(GS_KEY_TIME, 0)
                pcall(gs.flush, gs)
            end

            local function run_check()
                local screen
                screen = ZenScreen:new{
                    subtitle     = _("Checking for updates…"),
                    button       = _("Cancel"),
                    later_button = false,
                    dismissable  = false,
                }
                UIManager:show(screen)
                UIManager:forceRePaint()
                UIManager:scheduleIn(0.1, function()
                    network_check_async(
                        screen,
                        function(_co)
                            screen._on_button_action = function()
                                screen._on_button_action = nil
                                coroutine.resume(_co, false)
                            end
                        end,
                        function(net_ok)
                            screen._on_button_action = nil
                            if net_ok then
                                M._checked = true
                                persist_state(os.time())
                            else
                                load_cached_state()
                            end
                            if not net_ok then
                                screen:update{
                                    subtitle    = _("Could not reach update server. Check your internet connection."),
                                    button      = _("OK"),
                                    dismissable = true,
                                }
                            elseif M._has_update then
                                screen:update{ dismissable = true }
                                UIManager:close(screen)
                                _show_update_screen_and_install(plugin)
                            else
                                screen:update{
                                    subtitle    = _("Zen UI is up to date."),
                                    button      = _("OK"),
                                    dismissable = true,
                                }
                            end
                        end,
                        function()
                            screen._on_button_action = nil
                            screen:onClose()
                        end
                    )
                end)
            end

            if ok_nm and NetworkMgr and not NetworkMgr:isWifiOn() then
                NetworkMgr:runWhenOnline(run_check)
            else
                run_check()
            end
        end,
    }
end

--- Returns the active update channel: "stable" (default) or "beta".
function M.get_channel()
    return get_channel()
end

--- Set the update channel and reset cached state so the next check uses it.
function M.set_channel(ch)
    local gs = get_gs()
    if not gs then return end
    gs:saveSetting(GS_KEY_CHANNEL, ch == "beta" and "beta" or "stable")
    pcall(gs.flush, gs)
    -- Invalidate cache so next check_for_update() goes to the network.
    M._checked    = false
    M._has_update = false
    M._latest_ver = nil
    M._dl_url     = nil
    gs:saveSetting(GS_KEY_TIME, 0)
    pcall(gs.flush, gs)
end

--- Returns a radio-style "Update channel" sub-menu item for the About section.
function M.build_channel_item()
    return {
        text = _("Update channel"),
        sub_item_table = {
            {
                text = _("Stable"),
                checked_func = function() return get_channel() == "stable" end,
                callback = function() M.set_channel("stable") end,
            },
            {
                text = _("Beta"),
                checked_func = function() return get_channel() == "beta" end,
                callback = function() M.set_channel("beta") end,
            },
        },
    }
end

return M
