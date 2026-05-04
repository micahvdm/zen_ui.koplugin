-- Post-update "What's New" bullet lists, keyed by version string.
-- Add an entry for each release with noteworthy changes.
-- Omit a version to show no changelog on that update.
--
-- Example:
-- ["0.1.0"] = {
--     "New feature added",
--     "Bug fix for ...",
-- },

return {
    ["1.0.2"] = {
        "Automatically disable incompatible plugins",
        "Access reader menu from page browser",
        'Add "Report a Bug" button in Zen Settings > About',
        "Add in-app changelogs",
        "Add new quick settings buttons, hide when plugin not installed",
        "Add Bulgarian translation",
        "Bug fixes and performance improvements",
    },
    ["1.0.3"] = {
        "Fix: some quick settings buttons not showing",
        "Fix: language defaulting to english after plugin restart",
        "Bug fixes and performance improvements",
    },
    ["1.0.3-1"] = {
        "New: Zen Bible Mode module with dedicated Navbar tab",
        "New: Dynamic Bible scanning, folder picker, and Daily Verse feature",
    },
}
