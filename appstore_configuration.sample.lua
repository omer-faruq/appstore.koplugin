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

    -- Optional: GitHub download mirror / proxy prefix. Both keys below are only
    -- an initial default: as soon as a download source is picked in the UI
    -- (gear icon -> Download source) that stored choice wins from then on, even
    -- when it is "direct". Downloads and raw file fetches are routed; calls to
    -- api.github.com are not, so that the token above never reaches the mirror.
    -- Supported preset IDs: "direct" (default), "gh_proxy_com", "gh_ddlc_top", "ghproxy_net", "custom"
    -- download_mirror_preset = "gh_proxy_com",
    -- Custom prefix. Setting only this one implies download_mirror_preset = "custom";
    -- it is stored under the "download_mirror_custom_url" settings key once edited in the UI.
    -- download_mirror_prefix = "https://gh-proxy.com/",
}

