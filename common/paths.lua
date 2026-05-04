-- common/paths.lua
-- Shared path utilities: Android symlink normalization and home-dir helpers.
-- All modules that compare or gate on home_dir should use these instead of
-- inline /sdcard → /storage/emulated/0 substitutions.

local M = {}

-- Normalize the Android /sdcard symlink to its canonical /storage/emulated/0
-- form so prefix comparisons are consistent regardless of which path form
-- KOReader or the SQLite cache happens to store.
function M.normPath(p)
    if not p then return p end
    return (p:gsub("^/sdcard/", "/storage/emulated/0/")
             :gsub("^/sdcard$",  "/storage/emulated/0"))
end

-- Returns the user's home dir (library root) from G_reader_settings:
-- normalized via normPath and stripped of any trailing slash.
-- Returns nil when home_dir is not set.
function M.getHomeDir()
    local g = rawget(_G, "G_reader_settings")
    local d = g and g:readSetting("home_dir")
    if d and d ~= "" then
        return M.normPath(d:gsub("/*$", ""))
    end
    return nil
end

-- Returns true if path is at or directly under home_dir,
-- or under any additional home dirs configured in zen_ui_config.
-- Both path and home_dir are normalized before the comparison.
function M.isInHomeDir(path)
    if not path then return false end
    local norm = M.normPath(path:gsub("/$", ""))

    local home = M.getHomeDir()
    if home and (norm == home or norm:sub(1, #home + 1) == home .. "/") then
        return true
    end

    -- Check additional home dirs from zen config.
    local g = rawget(_G, "G_reader_settings")
    local zen_cfg = g and g:readSetting("zen_ui_config")
    local extra = type(zen_cfg) == "table" and zen_cfg.additional_home_dirs
    if type(extra) == "table" then
        for _, dir in ipairs(extra) do
            local d = M.normPath(dir:gsub("/*$", ""))
            if d ~= "" and (norm == d or norm:sub(1, #d + 1) == d .. "/") then
                return true
            end
        end
    end

    return false
end

return M
