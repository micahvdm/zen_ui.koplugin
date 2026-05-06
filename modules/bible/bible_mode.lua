local _ = require("gettext")
local logger = require("logger")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local plugin_root = require("common/plugin_root")

local BibleMode = {
    -- Curated list of common abbreviations to keep the menu clean.
    -- Files matching these will appear first; others will follow.
    PREFERRED = { "ESV", "NIV", "NKJV", "AMP", "NLT", "KJV", "NASB", "CSB" },
    
    VERSES = {
        { ref = "Joshua 1:9", text = "Have I not commanded you? Be strong and courageous. Do not be frightened, and do not be dismayed, for the Lord your God is with you wherever you go." },
        { ref = "Proverbs 3:5-6", text = "Trust in the Lord with all your heart, and do not lean on your own understanding. In all your ways acknowledge him, and he will make straight your paths." },
        { ref = "Romans 8:28", text = "And we know that for those who love God all things work together for good, for those who are called according to his purpose." },
        { ref = "Philippians 4:13", text = "I can do all things through him who strengthens me." },
        { ref = "Isaiah 41:10", text = "Fear not, for I am with you; be not dismayed, for I am your God; I will strengthen you, I will help you, I will uphold you with my righteous right hand." },
        { ref = "Psalm 23:1", text = "The Lord is my shepherd; I shall not want." },
        { ref = "Matthew 11:28", text = "Come to me, all who labor and are heavy laden, and I will give you rest." },
        { ref = "2 Timothy 1:7", text = "For God gave us a spirit not of fear but of power and love and self-control." },
        { ref = "Lamentations 3:22-23", text = "The steadfast love of the Lord never ceases; his mercies never come to an end; they are new every morning; great is your faithfulness." },
    },

    DEFAULTS = {
        enabled = true,
        bibles_dir = "bibles",
        bibles_dir_absolute = "",
        last_translation = "ESV",
        translations = {
            ESV  = "ESV.epub",
            NIV  = "NIV.epub",
            NKJV = "NKJV.epub",
            AMP  = "AMP.epub",
            NLT  = "NLT.epub",
        },
    }
}

local function exists(path, mode)
    return path and path ~= "" and lfs.attributes(path, "mode") == mode
end

local function join_path(a, b)
    if not a or a == "" then return b end
    if a:sub(-1) == "/" then return a .. b end
    return a .. "/" .. b
end

function BibleMode.init(log, plugin)
    local self = BibleMode
    self.plugin = plugin

    -- Ensure config structure exists
    if not plugin.config.bible_mode then
        plugin.config.bible_mode = {}
    end
    for k, v in pairs(self.DEFAULTS) do
        if plugin.config.bible_mode[k] == nil then
            plugin.config.bible_mode[k] = type(v) == "table" and require("util").tableDeepCopy(v) or v
        end
    end

    -- Seed random generator once at init for the Daily Verse feature
    math.randomseed(os.time())

    -- Migration: check for settings from the old standalone "zen_bible_mode" key
    local old_settings = G_reader_settings:readSetting("zen_bible_mode")
    if old_settings and not plugin.config._meta.bible_migrated then
        for k, v in pairs(old_settings) do
            if plugin.config.bible_mode[k] == nil then
                plugin.config.bible_mode[k] = type(v) == "table" 
                    and require("util").tableDeepCopy(v) or v
            end
        end
        plugin.config._meta.bible_migrated = true
        plugin:saveConfig()
        logger.info("ZenUI: Bible Mode settings migrated from legacy plugin")
    end

    -- Attach to plugin for cross-module access (e.g., from Navbar)
    plugin.bible_mode = self
    logger.info("ZenUI: Bible Mode module initialized")
    return true
end

function BibleMode:biblesDir()
    local cfg = self.plugin.config.bible_mode
    if cfg.bibles_dir_absolute and cfg.bibles_dir_absolute ~= "" then
        return cfg.bibles_dir_absolute
    end

    -- Try plugin root first
    local internal = join_path(plugin_root, cfg.bibles_dir or "bibles")
    if exists(internal, "directory") then return internal end

    -- Fallback to KOReader base
    return join_path(lfs.currentdir(), cfg.bibles_dir or "bibles")
end

function BibleMode:scanTranslations(force_refresh)
    if not force_refresh and self._cached_translations then
        return self._cached_translations
    end

    local dir = self:biblesDir()
    local found = {}
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if ok then
        for file in iter, dir_obj do
            if file:lower():match("%.epub$") then
                local name = file:gsub("%.epub$", ""):gsub("%.EPUB$", "")
                table.insert(found, { name = name, file = file })
            end
        end
    end

    -- Sort logic: preferred translations first, then alphabetical
    local preferred_map = {}
    for i, p in ipairs(self.PREFERRED) do preferred_map[p] = i end

    table.sort(found, function(a, b)
        local ap = preferred_map[a.name]
        local bp = preferred_map[b.name]
        if ap and bp then return ap < bp end
        if ap then return true end
        if bp then return false end
        return a.name < b.name
    end)

    self._cached_translations = found
    return found
end

function BibleMode:setTranslation(code)
    local cfg = self.plugin.config.bible_mode
    if cfg.last_translation ~= code then
        cfg.last_translation = code
        self.plugin:saveConfig()
    end
end

function BibleMode:openTranslation(code)
    local cfg = self.plugin.config.bible_mode
    local installed = self:scanTranslations()

    if #installed == 0 then
        UIManager:show(InfoMessage:new{ 
            text = _("No Bible EPUBs found in: ") .. self:biblesDir() .. "\n\n" .. _("Please place your Bible EPUBs there or change the folder in settings.")
        })
        return
    end

    code = code or cfg.last_translation or "ESV"

    local match
    for _, t in ipairs(installed) do
        if t.name == code then
            match = t
            break
        end
    end

    -- If the requested translation is missing, fallback to the first one available
    if not match then
        match = installed[1]
        code = match.name
    end

    local path = join_path(self:biblesDir(), match.file)
    if not exists(path, "file") then
        UIManager:show(InfoMessage:new{ 
            text = _("Bible file not found: ") .. tostring(match.file) .. "\n\n" .. _("Please select a valid translation in settings.")
        })
        return
    end

    self:setTranslation(code)

    -- Try to use FileManager to open the file if it's running
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager and FileManager.instance

    if fm then
        local ok_utils, utils = pcall(require, "common/utils")
        if ok_utils and utils and type(utils.closeWidgetsAbove) == "function" then
            pcall(utils.closeWidgetsAbove, fm)
        end

        -- Use openFile instead of showFile to avoid navigating the File Manager
        -- away from the user's library/home directory.
        if type(fm.openFile) == "function" then
            fm:openFile(path)
            return
        end
    end

    -- Fallback to direct reader
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
end

function BibleMode:showDailyVerse()
    local v = self.VERSES[math.random(#self.VERSES)]
    UIManager:show(InfoMessage:new{
        text = v.text .. "\n\n— " .. v.ref,
    })
end

function BibleMode:changeFolder()
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    filemanagerutil.showChooseDialog(
        _("Select Bible Folder"),
        function(path)
            self.plugin.config.bible_mode.bibles_dir_absolute = path
            self._cached_translations = nil -- invalidate cache
            self.plugin:saveConfig()
        end,
        self:biblesDir(),
        "/"
    )
end

function BibleMode:getMenuItems()
    local items = {}
    local cfg = self.plugin.config.bible_mode
    local installed = self:scanTranslations()

    table.insert(items, {
        text = _("Open Bible"),
        callback = function() self:openTranslation() end,
    })

    table.insert(items, {
        text = _("Daily Verse"),
        callback = function() self:showDailyVerse() end,
    })

    local translation_items = {}
    for _, t in ipairs(installed) do
        table.insert(translation_items, {
            text = t.name,
            checked = (t.name == cfg.last_translation),
            callback = function(touchmenu_instance)
                self:setTranslation(t.name)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
    end

    table.insert(items, {
        text = _("Select translation"),
        sub_item_table = translation_items,
        enabled = #installed > 0,
    })

    table.insert(items, { separator = true })

    table.insert(items, {
        text = _("Change Bible folder..."),
        callback = function() self:changeFolder() end,
    })

    table.insert(items, {
        text = _("Show current path"),
        callback = function()
            UIManager:show(InfoMessage:new{
                text = _("Place Bible EPUBs in: ") .. self:biblesDir()
            })
        end,
    })

    return items
end

return BibleMode