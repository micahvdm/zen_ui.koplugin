local defaults = require("config/defaults")
local utils = require("common/utils")

local KEY = "zen_ui_config"
local M = {}

local function merged_with_defaults(stored)
    local cfg = utils.deepcopy(defaults)
    if type(stored) == "table" then
        utils.deepmerge(stored, cfg)
        cfg = stored
    end
    utils.deepmerge(cfg, defaults)
    return cfg
end

local function normalize_renamed_keys(cfg)
    if type(cfg) ~= "table" then
        return cfg
    end

    cfg.features = cfg.features or {}

    if cfg.features.disable_top_menu_swipe_zones == nil
       and cfg.features.disable_top_menu_zones ~= nil then
        cfg.features.disable_top_menu_swipe_zones = cfg.features.disable_top_menu_zones
    end

    if cfg.features.browser_hide_up_folder == nil
       and cfg.features.browser_up_folder ~= nil then
        cfg.features.browser_hide_up_folder = cfg.features.browser_up_folder
    end

    if cfg.browser_hide_up_folder == nil and cfg.browser_up_folder ~= nil then
        cfg.browser_hide_up_folder = cfg.browser_up_folder
    end

    -- Always-on features: no user toggle in Zen settings.
    cfg.features.browser_folder_cover = true

    return cfg
end

local function collect_setting_keys(g_settings)
    local keys = {}

    if type(g_settings.pairs) == "function" then
        local ok_pairs, iterator, state, first_key = pcall(g_settings.pairs, g_settings)
        if ok_pairs and type(iterator) == "function" then
            local key_name = first_key
            while true do
                local next_key = iterator(state, key_name)
                if next_key == nil then break end
                if type(next_key) == "string" then
                    keys[next_key] = true
                end
                key_name = next_key
            end
        end
    end

    local tables_to_scan = {
        rawget(g_settings, "data"),
        rawget(g_settings, "settings"),
        rawget(g_settings, "_data"),
    }

    for i = 1, #tables_to_scan do
        local tbl = tables_to_scan[i]
        if type(tbl) == "table" then
            for key_name in pairs(tbl) do
                if type(key_name) == "string" then
                    keys[key_name] = true
                end
            end
        end
    end

    if type(g_settings) == "table" then
        for key_name in pairs(g_settings) do
            if type(key_name) == "string" then
                keys[key_name] = true
            end
        end
    end

    return keys
end

local function migrate_legacy_group_view_keys(cfg)
    local g = rawget(_G, "G_reader_settings")
    if not g or type(cfg) ~= "table" then
        return cfg, false
    end

    local changed = false
    local removed_legacy = false

    local function ensure_group_view()
        if type(cfg.group_view) ~= "table" then
            cfg.group_view = {}
            changed = true
        end
        return cfg.group_view
    end

    local function ensure_display_mode()
        local group_view = ensure_group_view()
        if type(group_view.display_mode) ~= "table" then
            group_view.display_mode = {}
            changed = true
        end
        return group_view.display_mode
    end

    local function ensure_detail_collate(tab_id)
        local group_view = ensure_group_view()
        if type(group_view.detail_collate) ~= "table" then
            group_view.detail_collate = {}
            changed = true
        end
        local detail_collate = group_view.detail_collate
        if type(detail_collate[tab_id]) ~= "table" then
            detail_collate[tab_id] = {}
            changed = true
        end
        return detail_collate[tab_id]
    end

    local setting_keys = collect_setting_keys(g)

    for key_name in pairs(setting_keys) do
        local display_tab = key_name:match("^zen_(.+)_display_mode$")
        if display_tab then
            local legacy_value = g:readSetting(key_name)
            if legacy_value ~= nil then
                local display_mode = ensure_display_mode()
                if display_mode[display_tab] == nil then
                    display_mode[display_tab] = legacy_value
                    changed = true
                end
                g:delSetting(key_name)
                removed_legacy = true
            end
        else
            local detail_tab, group_name = key_name:match("^zen_(.+)_detail_collate_(.+)$")
            if detail_tab and group_name then
                local legacy_value = g:readSetting(key_name)
                if legacy_value ~= nil then
                    local detail_collate = ensure_detail_collate(detail_tab)
                    if detail_collate[group_name] == nil then
                        detail_collate[group_name] = legacy_value
                        changed = true
                    end
                    g:delSetting(key_name)
                    removed_legacy = true
                end
            end
        end
    end

    local legacy_layout = g:readSetting("zen_page_browser_layout")
    if legacy_layout ~= nil then
        if type(cfg.reader_page_browser) ~= "table" then
            cfg.reader_page_browser = {}
            changed = true
        end
        if cfg.reader_page_browser.layout == nil then
            cfg.reader_page_browser.layout = legacy_layout
            changed = true
        end
        g:delSetting("zen_page_browser_layout")
        removed_legacy = true
    end

    if removed_legacy then
        pcall(g.flush, g)
    end

    return cfg, (changed or removed_legacy)
end

function M.load()
    local stored = G_reader_settings:readSetting(KEY, {})
    local cfg = merged_with_defaults(stored)
    cfg = normalize_renamed_keys(cfg)
    local migrated
    cfg, migrated = migrate_legacy_group_view_keys(cfg)
    if migrated then
        M.save(cfg)
    end
    return cfg
end

function M.save(config)
    G_reader_settings:saveSetting(KEY, config)
end

function M.key()
    return KEY
end

return M
