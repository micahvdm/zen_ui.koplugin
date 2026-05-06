-- settings/sections/library/navbar.lua
-- Navbar settings item for Zen UI.
-- Returns a single menu-item table: { text = _("Navbar"), sub_item_table = {...} }
-- Receives ctx: { config, save_and_apply, apply_feature }

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local utils = require("modules/settings/zen_settings_utils")
local paths = require("common/paths")

local M = {}

function M.build(ctx)
    local config        = ctx.config
    local plugin        = ctx.plugin
    local save_and_apply = ctx.save_and_apply
    local apply_feature  = ctx.apply_feature

    -- For config-only changes (visibility, styling), reinject directly so the
    -- navbar rebuilds immediately in the widget tree and shows correct tabs as
    -- soon as the menu closes -- no deferred polling needed.
    local function save_and_apply_navbar()
        ctx.plugin:saveConfig()
        local reinject = rawget(_G, "__ZEN_UI_REINJECT_FM_NAVBAR")
        if reinject then reinject() else save_and_apply("navbar") end
    end

    local function make_enable_feature_item(feature, text)
        return utils.make_enable_feature_item(feature, text, config, save_and_apply)
    end

    -- -------------------------------------------------------------------------
    -- Color helpers
    -- -------------------------------------------------------------------------

    local function ensure_navbar_color()
        local c = config.navbar.active_tab_color
        if type(c) ~= "table" then
            c = { 0x33, 0x99, 0xFF }
            config.navbar.active_tab_color = c
        end
        c[1] = tonumber(c[1]) or 0x33
        c[2] = tonumber(c[2]) or 0x99
        c[3] = tonumber(c[3]) or 0xFF
        c[1] = math.max(0, math.min(255, c[1]))
        c[2] = math.max(0, math.min(255, c[2]))
        c[3] = math.max(0, math.min(255, c[3]))
        return c
    end

    local function set_navbar_color(r, g, b)
        config.navbar.active_tab_color = {
            math.max(0, math.min(255, tonumber(r) or 0)),
            math.max(0, math.min(255, tonumber(g) or 0)),
            math.max(0, math.min(255, tonumber(b) or 0)),
        }
    end

    -- -------------------------------------------------------------------------
    -- Tab definitions
    -- -------------------------------------------------------------------------

    local navbar_tab_items = {
        { id = "books",       text = _("Books")         },
        { id = "manga",       text = _("Manga")         },
        { id = "news",        text = _("News")          },
        { id = "bible",       text = _("Bible")         },
        { id = "continue",    text = _("Continue")      },
        { id = "history",     text = _("History")       },
        { id = "favorites",   text = _("Favorites")     },
        { id = "collections", text = _("Collections")   },
        { id = "authors",     text = _("Authors")       },
        { id = "series",      text = _("Series")        },
        { id = "tags",        text = _("Tags")          },
        { id = "to_be_read",  text = _("To Be Read")    },
        { id = "search",         text = _("Search")          },
        { id = "calibre_search", text = _("Calibre Search")  },
        { id = "stats",          text = _("Stats")            },
        { id = "exit",        text = _("Exit")          },
        { id = "page_left",   text = _("Previous page") },
        { id = "page_right",  text = _("Next page")     },
        { id = "menu",        text = _("Menu")          },
    }

    local navbar_max_tabs = 7

    local function countEnabledTabs()
        local count = 1 -- books is always shown
        for id, v in pairs(config.navbar.show_tabs) do
            if id ~= "books" and v == true then
                count = count + 1
            end
        end
        return count
    end

    local navbar_tab_toggle_items = {}
    for i, tab in ipairs(navbar_tab_items) do
        if tab.id ~= "books" then
            local tab_id = tab.id
            table.insert(navbar_tab_toggle_items, {
                text = tab.text,
                checked_func = function()
                    return config.navbar.show_tabs[tab_id] == true
                end,
                enabled_func = function()
                    return config.navbar.show_tabs[tab_id] == true
                        or countEnabledTabs() < navbar_max_tabs
                end,
                callback = function()
                    config.navbar.show_tabs[tab_id] = not (config.navbar.show_tabs[tab_id] == true)
                    save_and_apply_navbar()
                end,
            })
        end
    end

    -- -------------------------------------------------------------------------
    -- Custom tab helpers
    -- -------------------------------------------------------------------------

    local ok_disp, Dispatcher = pcall(require, "dispatcher")

    local function get_ct_label(ct)
        if ct.label and ct.label ~= "" then return ct.label end
        if ok_disp and ct.action and next(ct.action) then
            local t = Dispatcher:menuTextFunc(ct.action)
            if t ~= _("Nothing") then return t end
        end
        return _("Custom")
    end

    local CUSTOM_TAB_ICONS
    local function getCustomTabIcons()
        if CUSTOM_TAB_ICONS then return CUSTOM_TAB_ICONS end
        local excluded = { zen_ui_light = true, zen_ui_update = true }
        local icons = {}
        local ok_lfs, lfs_mod = pcall(require, "libs/libkoreader-lfs")
        local root = ok_lfs and lfs_mod and require("common/plugin_root")
        if root then
            local icons_dir = root .. "/icons"
            for f in lfs_mod.dir(icons_dir) do
                if f:match("%.svg$") and not f:match("%.bak%.svg$") then
                    local name = f:sub(1, -5)
                    if not excluded[name] then icons[#icons + 1] = name end
                end
            end
            table.sort(icons)
        end
        CUSTOM_TAB_ICONS = icons
        return CUSTOM_TAB_ICONS
    end

    local _icon_picker = require("common/zen_icon_picker")
    local function showTabIconPicker(ct, on_select)
        local ok_root, root = pcall(require, "common/plugin_root")
        if not ok_root or not root then return end
        _icon_picker(getCustomTabIcons(), root .. "/icons", ct.icon, on_select)
    end

    local build_ct_sub_items  -- forward decl
    build_ct_sub_items = function(ct)
        local items = {}

        table.insert(items, {
            text = _("Show in navbar"),
            separator = true,
            checked_func = function() return config.navbar.show_tabs[ct.id] ~= false end,
            enabled_func = function()
                return config.navbar.show_tabs[ct.id] ~= false
                    or countEnabledTabs() < navbar_max_tabs
            end,
            callback = function()
                local cur = config.navbar.show_tabs[ct.id]
                config.navbar.show_tabs[ct.id] = (cur == false)
                save_and_apply_navbar()
            end,
        })

        if ok_disp then
            local dispatch_items = {}
            local caller = setmetatable({}, {
                __newindex = function(t, k, v)
                    if k == "updated" and v then
                        save_and_apply("navbar")
                    else
                        rawset(t, k, v)
                    end
                end,
                __index = function() return nil end,
            })
            Dispatcher:addSubMenu(caller, dispatch_items, ct, "action")
            table.insert(items, {
                text_func = function()
                    if ct.action and next(ct.action) then
                        return T(_("Action: %1"), Dispatcher:menuTextFunc(ct.action))
                    end
                    return _("Action: (none)")
                end,
                keep_menu_open = true,
                sub_item_table = dispatch_items,
            })
        end

        table.insert(items, {
            text_func = function()
                return T(_("Icon: %1"), ct.icon or "zen_ui")
            end,
            keep_menu_open = true,
            callback = function(tm)
                showTabIconPicker(ct, function(name)
                    ct.icon = name
                    save_and_apply("navbar")
                    if tm and tm.updateItems then tm:updateItems(1) end
                end)
            end,
        })

        table.insert(items, {
            text_func = function()
                local lbl = (ct.label and ct.label ~= "") and ct.label or _("(auto)")
                return T(_("Label: %1"), lbl)
            end,
            keep_menu_open = true,
            callback = function()
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new{
                    title = _("Custom tab label"),
                    input = ct.label or "",
                    input_hint = _("Leave empty to use action title"),
                    buttons = {{
                        { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                        {
                            text = _("Set"),
                            is_enter_default = true,
                            callback = function()
                                local txt = dialog:getInputText()
                                ct.label = (txt and txt ~= "") and txt or nil
                                UIManager:close(dialog)
                                save_and_apply("navbar")
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
            end,
        })

        table.insert(items, {
            text = _("Remove this tab"),
            separator = true,
            keep_menu_open = true,
            callback = function(touch_menu)
                local cts = config.navbar.custom_tabs
                for i, item in ipairs(cts) do
                    if item.id == ct.id then table.remove(cts, i); break end
                end
                config.navbar.show_tabs[ct.id] = nil
                local new_order = {}
                for _, id in ipairs(config.navbar.tab_order) do
                    if id ~= ct.id then new_order[#new_order + 1] = id end
                end
                config.navbar.tab_order = new_order
                save_and_apply("navbar")
                if touch_menu then touch_menu:backToUpperMenu() end
            end,
        })

        return items
    end

    -- -------------------------------------------------------------------------
    -- Navbar item
    -- -------------------------------------------------------------------------

    return {
        text = _("Navbar"),
        sub_item_table = {
            {
                text = _("Tabs"),
                sub_item_table = {
                    {
                        text = _("Visibility"),
                        sub_item_table = navbar_tab_toggle_items,
                    },
                    {
                        text = _("Custom tabs"),
                        keep_menu_open = true,
                        sub_item_table_func = function()
                            local function build()
                                local items = {}
                                table.insert(items, {
                                    text = _("Add custom tab"),
                                    keep_menu_open = true,
                                    callback = function(touch_menu)
                                        if type(config.navbar.custom_tabs) ~= "table" then
                                            config.navbar.custom_tabs = {}
                                        end
                                        local cts = config.navbar.custom_tabs
                                        config.navbar.next_custom_id =
                                            (config.navbar.next_custom_id or 0) + 1
                                        local new_ct = {
                                            id     = "ct_" .. config.navbar.next_custom_id,
                                            label  = nil,
                                            icon   = "zen_ui",
                                            action = {},
                                        }
                                        table.insert(cts, new_ct)
                                        config.navbar.show_tabs[new_ct.id] =
                                            countEnabledTabs() < navbar_max_tabs
                                        -- Insert before page_right/menu in tab_order
                                        local order = config.navbar.tab_order
                                        local inserted = false
                                        for i, id in ipairs(order) do
                                            if id == "page_right" or id == "menu" then
                                                table.insert(order, i, new_ct.id)
                                                inserted = true
                                                break
                                            end
                                        end
                                        if not inserted then order[#order + 1] = new_ct.id end
                                        save_and_apply("navbar")
                                        local sub_items = build_ct_sub_items(new_ct)
                                        if touch_menu and #sub_items > 0 then
                                            table.insert(touch_menu.item_table_stack, touch_menu.item_table)
                                            touch_menu.parent_id = nil
                                            touch_menu.item_table = sub_items
                                            touch_menu:updateItems(1)
                                        end
                                    end,
                                })
                                if type(config.navbar.custom_tabs) == "table" then
                                    for _i, ct in ipairs(config.navbar.custom_tabs) do
                                        local ct_ref = ct
                                        table.insert(items, {
                                            text_func = function() return get_ct_label(ct_ref) end,
                                            keep_menu_open = true,
                                            sub_item_table_func = function()
                                                return build_ct_sub_items(ct_ref)
                                            end,
                                        })
                                    end
                                end
                                items.needs_refresh = true
                                items.refresh_func = build
                                return items
                            end
                            return build()
                        end,
                    },
                    {
                        text = _("Arrange tabs"),
                        separator = true,
                        keep_menu_open = true,
                        callback = function()
                            local SortWidget = require("ui/widget/sortwidget")
                            local sort_items = {}
                            for _, tab in ipairs(navbar_tab_items) do
                                local is_visible = tab.id == "books" or config.navbar.show_tabs[tab.id] == true
                                table.insert(sort_items, {
                                    text = tab.text,
                                    orig_item = tab.id,
                                    dim = not is_visible,
                                })
                            end
                            if type(config.navbar.custom_tabs) == "table" then
                                for _i, ct in ipairs(config.navbar.custom_tabs) do
                                    table.insert(sort_items, {
                                        text = get_ct_label(ct),
                                        orig_item = ct.id,
                                        dim = not (config.navbar.show_tabs[ct.id] == true),
                                    })
                                end
                            end
                            UIManager:show(SortWidget:new{
                                title = _("Arrange navbar tabs"),
                                item_table = sort_items,
                                callback = function()
                                    local new_order = {}
                                    local in_sort = {}
                                    for _, item in ipairs(sort_items) do
                                        new_order[#new_order + 1] = item.orig_item
                                        in_sort[item.orig_item] = true
                                    end
                                    -- Preserve any IDs not in the sort widget
                                    for _, id in ipairs(config.navbar.tab_order) do
                                        if not in_sort[id] then new_order[#new_order + 1] = id end
                                    end
                                    config.navbar.tab_order = new_order
                                    save_and_apply_navbar()
                                end,
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local label = config.navbar.books_label
                            if label == nil or label == "" then label = _("Library") end
                            return _("Books tab label: ") .. label
                        end,
                        separator = true,
                        sub_item_table = {
                            {
                                text = _("Books"),
                                checked_func = function()
                                    return config.navbar.books_label == "Books"
                                end,
                                callback = function()
                                    config.navbar.books_label = "Books"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Home"),
                                checked_func = function() return config.navbar.books_label == "Home" end,
                                callback = function()
                                    config.navbar.books_label = "Home"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Library"),
                                checked_func = function()
                                    local l = config.navbar.books_label
                                    return l == nil or l == "" or l == "Library"
                                end,
                                callback = function()
                                    config.navbar.books_label = ""
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    local label = config.navbar.books_label or ""
                                    local presets = { [""] = true, Books = true, Home = true, Library = true }
                                    if presets[label] then return _("Custom") end
                                    return _("Custom: ") .. label
                                end,
                                checked_func = function()
                                    local label = config.navbar.books_label or ""
                                    local presets = { [""] = true, Books = true, Home = true, Library = true }
                                    return not presets[label]
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local InputDialog = require("ui/widget/inputdialog")
                                    local dlg
                                    dlg = InputDialog:new{
                                        title = _("Books tab label"),
                                        input = config.navbar.books_label or "",
                                        buttons = {{
                                            {
                                                text = _("Cancel"),
                                                id = "close",
                                                callback = function() UIManager:close(dlg) end,
                                            },
                                            {
                                                text = _("Set"),
                                                is_enter_default = true,
                                                callback = function()
                                                    local text = dlg:getInputText()
                                                    config.navbar.books_label = text ~= "" and text or "Books"
                                                    UIManager:close(dlg)
                                                    save_and_apply_navbar()
                                                    if touchmenu_instance then
                                                        touchmenu_instance:updateItems()
                                                    end
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(dlg)
                                    dlg:onShowKeyboard()
                                end,
                            },
                        },
                    },
                    {
                        text_func = function()
                            if config.navbar.manga_action == "folder" then
                                return _("Manga tab action: ") .. _("Folder")
                            end
                            return _("Manga tab action: ") .. _("Rakuyomi")
                        end,
                        separator = true,
                        sub_item_table = {
                            {
                                text = _("Open Rakuyomi"),
                                checked_func = function() return config.navbar.manga_action ~= "folder" end,
                                callback = function()
                                    config.navbar.manga_action = "rakuyomi"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    if config.navbar.manga_action == "folder" and config.navbar.manga_folder ~= "" then
                                        local util = require("util")
                                        local _dir, folder_name = util.splitFilePathName(config.navbar.manga_folder)
                                        return _("Open folder: ") .. folder_name
                                    end
                                    return _("Open folder")
                                end,
                                checked_func = function() return config.navbar.manga_action == "folder" end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local PathChooser = require("ui/widget/pathchooser")
                                    local start_path = config.navbar.manga_folder ~= "" and config.navbar.manga_folder
                                        or G_reader_settings:readSetting("lastdir") or "/"
                                    local path_chooser = PathChooser:new{
                                        select_file = false,
                                        show_files = false,
                                        path = start_path,
                                        onConfirm = function(dir_path)
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = dir_path
                                            save_and_apply_navbar()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end,
                                    }
                                    UIManager:show(path_chooser)
                                end,
                            },
                            {
                                text = _("Folder presets"),
                                sub_item_table = {
                                    {
                                        text = _("Use home folder"),
                                        callback = function()
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = paths.getHomeDir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use last folder"),
                                        callback = function()
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = utils.get_last_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use current folder"),
                                        callback = function()
                                            config.navbar.manga_action = "folder"
                                            config.navbar.manga_folder = utils.get_current_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                },
                            },
                        },
                    },
                    {
                        text_func = function()
                            if config.navbar.news_action == "folder" then
                                return _("News tab action: ") .. _("Folder")
                            elseif config.navbar.news_action == "rssreader" then
                                return _("News tab action: ") .. _("RSS Reader")
                            end
                            return _("News tab action: ") .. _("QuickRSS")
                        end,
                        separator = true,
                        sub_item_table = {
                            {
                                text = _("Open QuickRSS"),
                                checked_func = function()
                                    return config.navbar.news_action ~= "folder"
                                        and config.navbar.news_action ~= "rssreader"
                                end,
                                callback = function()
                                    config.navbar.news_action = "quickrss"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Open RSS Reader"),
                                checked_func = function() return config.navbar.news_action == "rssreader" end,
                                callback = function()
                                    config.navbar.news_action = "rssreader"
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    if config.navbar.news_action == "folder" and config.navbar.news_folder ~= "" then
                                        local util = require("util")
                                        local _dir, folder_name = util.splitFilePathName(config.navbar.news_folder)
                                        return _("Open folder: ") .. folder_name
                                    end
                                    return _("Open folder")
                                end,
                                checked_func = function() return config.navbar.news_action == "folder" end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local PathChooser = require("ui/widget/pathchooser")
                                    local start_path = config.navbar.news_folder ~= "" and config.navbar.news_folder
                                        or G_reader_settings:readSetting("lastdir") or "/"
                                    local path_chooser = PathChooser:new{
                                        select_file = false,
                                        show_files = false,
                                        path = start_path,
                                        onConfirm = function(dir_path)
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = dir_path
                                            save_and_apply_navbar()
                                            if touchmenu_instance then
                                                touchmenu_instance:updateItems()
                                            end
                                        end,
                                    }
                                    UIManager:show(path_chooser)
                                end,
                            },
                            {
                                text = _("Folder presets"),
                                sub_item_table = {
                                    {
                                        text = _("Use home folder"),
                                        callback = function()
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = paths.getHomeDir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use last folder"),
                                        callback = function()
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = utils.get_last_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                    {
                                        text = _("Use current folder"),
                                        callback = function()
                                            config.navbar.news_action = "folder"
                                            config.navbar.news_folder = utils.get_current_dir()
                                            save_and_apply_navbar()
                                        end,
                                    },
                                },
                            },
                        },
                    },
                    {
                        text_func = function()
                            local trans = config.bible_mode and config.bible_mode.last_translation or "ESV"
                            return _("Bible translation: ") .. trans
                        end,
                        separator = true,
                        show_func = function() return plugin.bible_mode ~= nil end,
                        sub_item_table_func = function()
                            return plugin.bible_mode:getMenuItems()
                        end,
                    },
                    {
                        text = _("Visibility"),
                        sub_item_table = navbar_tab_toggle_items,
                    },
                    {
                        text = _("Arrange tabs"),
                        keep_menu_open = true,
                        callback = function()
                            local SortWidget = require("ui/widget/sortwidget")
                            local sort_items = {}
                            for _, tab in ipairs(navbar_tab_items) do
                                local is_visible = tab.id == "books" or config.navbar.show_tabs[tab.id] == true
                                table.insert(sort_items, {
                                    text = tab.text,
                                    orig_item = tab.id,
                                    dim = not is_visible,
                                })
                            end
                            UIManager:show(SortWidget:new{
                                title = _("Arrange navbar tabs"),
                                item_table = sort_items,
                                callback = function()
                                    for i, item in ipairs(sort_items) do
                                        config.navbar.tab_order[i] = item.orig_item
                                    end
                                    save_and_apply_navbar()
                                end,
                            })
                        end,
                    },
                },
            },
            {
                text = _("Styling"),
                sub_item_table = {
                    {
                        text = _("Show top border"),
                        checked_func = function() return config.navbar.show_top_border == true end,
                        callback = function()
                            config.navbar.show_top_border = not (config.navbar.show_top_border == true)
                            save_and_apply("navbar")
                        end,
                    },
                    {
                        text = _("Active tab styling"),
                        checked_func = function() return config.navbar.active_tab_styling == true end,
                        callback = function()
                            config.navbar.active_tab_styling = not (config.navbar.active_tab_styling == true)
                            save_and_apply("navbar")
                        end,
                    },
                    {
                        text = _("Bold active tab"),
                        checked_func = function() return config.navbar.active_tab_bold == true end,
                        enabled_func = function() return config.navbar.active_tab_styling == true end,
                        callback = function()
                            config.navbar.active_tab_bold = not (config.navbar.active_tab_bold == true)
                            save_and_apply("navbar")
                        end,
                    },
                    {
                        text = _("Active tab underline"),
                        checked_func = function() return config.navbar.active_tab_underline == true end,
                        enabled_func = function() return config.navbar.active_tab_styling == true end,
                        callback = function()
                            config.navbar.active_tab_underline = not (config.navbar.active_tab_underline == true)
                            save_and_apply("navbar")
                        end,
                    },
                    {
                        text = _("Underline above icon"),
                        checked_func = function() return config.navbar.underline_above == true end,
                        enabled_func = function()
                            return config.navbar.active_tab_styling == true
                                and config.navbar.active_tab_underline == true
                        end,
                        callback = function()
                            config.navbar.underline_above = not (config.navbar.underline_above == true)
                            save_and_apply("navbar")
                        end,
                    },
                    {
                        text = _("Colored active tab"),
                        checked_func = function() return config.navbar.colored == true end,
                        enabled_func = function() return config.navbar.active_tab_styling == true end,
                        callback = function()
                            config.navbar.colored = not (config.navbar.colored == true)
                            save_and_apply_navbar()
                        end,
                    },
                    {
                        text_func = function()
                            local c = ensure_navbar_color()
                            return _("Active tab color: ") .. string.format("%d,%d,%d", c[1], c[2], c[3])
                        end,
                        enabled_func = function()
                            return config.navbar.active_tab_styling == true and config.navbar.colored == true
                        end,
                        sub_item_table = {
                            {
                                text = _("Blue"),
                                checked_func = function()
                                    local c = ensure_navbar_color()
                                    return c[1] == 0x33 and c[2] == 0x99 and c[3] == 0xFF
                                end,
                                callback = function()
                                    set_navbar_color(0x33, 0x99, 0xFF)
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Green"),
                                checked_func = function()
                                    local c = ensure_navbar_color()
                                    return c[1] == 0x33 and c[2] == 0xAA and c[3] == 0x55
                                end,
                                callback = function()
                                    set_navbar_color(0x33, 0xAA, 0x55)
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Amber"),
                                checked_func = function()
                                    local c = ensure_navbar_color()
                                    return c[1] == 0xFF and c[2] == 0xAA and c[3] == 0x00
                                end,
                                callback = function()
                                    set_navbar_color(0xFF, 0xAA, 0x00)
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text = _("Red"),
                                checked_func = function()
                                    local c = ensure_navbar_color()
                                    return c[1] == 0xDD and c[2] == 0x33 and c[3] == 0x33
                                end,
                                callback = function()
                                    set_navbar_color(0xDD, 0x33, 0x33)
                                    save_and_apply_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    local c = ensure_navbar_color()
                                    return _("Custom RGB") .. " (" .. string.format("%d,%d,%d", c[1], c[2], c[3]) .. ")"
                                end,
                                keep_menu_open = true,
                                callback = function(touchmenu_instance)
                                    local InputDialog = require("ui/widget/inputdialog")
                                    local c = ensure_navbar_color()
                                    local dlg
                                    dlg = InputDialog:new{
                                        title = _("Active tab RGB"),
                                        input = string.format("%d,%d,%d", c[1], c[2], c[3]),
                                        hint = _("Format: R,G,B (0-255)"),
                                        buttons = {{
                                            {
                                                text = _("Cancel"),
                                                id = "close",
                                                callback = function() UIManager:close(dlg) end,
                                            },
                                            {
                                                text = _("Set"),
                                                is_enter_default = true,
                                                callback = function()
                                                    local text = dlg:getInputText() or ""
                                                    local r, g, b = text:match("^%s*(%d+)%s*,%s*(%d+)%s*,%s*(%d+)%s*$")
                                                    if r and g and b then
                                                        set_navbar_color(tonumber(r), tonumber(g), tonumber(b))
                                                        UIManager:close(dlg)
                                                        save_and_apply_navbar()
                                                        if touchmenu_instance then
                                                            touchmenu_instance:updateItems()
                                                        end
                                                    end
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(dlg)
                                    dlg:onShowKeyboard()
                                end,
                            },
                        },
                    },
                    {
                        text = _("Refresh navbar"),
                        keep_menu_open = true,
                        callback = function()
                            apply_feature("navbar")
                        end,
                    },
                },
            },
            {
                text = _("Show labels"),
                checked_func = function() return config.navbar.show_labels == true end,
                callback = function()
                    config.navbar.show_labels = not (config.navbar.show_labels == true)
                    save_and_apply("navbar")
                end,
            },
        },
    }
end

return M
