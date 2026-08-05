-- User-editable configuration for AppStore plugin.
-- Fill in your personal access tokens (PAT) here to raise API limits.
-- Example for GitHub: generate a PAT with "public_repo" scope and paste it below.
return {
    auth = {
        github = {
            type = "github",
            token = "your_github_token",
        },
    },

    -- Optional: force where freshly installed plugins are written to, when
    -- you have more than one directory listed in the "extra_plugin_paths"
    -- KOReader setting and don't want to be prompted each time. Must resolve
    -- (as a real, existing directory) to the bundled "plugins" folder or to
    -- one of the directories in "extra_plugin_paths", otherwise it's
    -- ignored -- use an absolute path matching one of your actual
    -- "extra_plugin_paths" entries, like the example below.
    -- plugin_install_path = "/home/user/.config/koreader/plugins-ext/",
}

