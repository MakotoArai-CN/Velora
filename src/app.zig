const builtin = @import("builtin");

pub const display_name = "Velora";
pub const command_name = "velora";
pub const config_dir_name = ".velora";
pub const sites_filename = "sites.json";

pub const subtitle_en = "Multi-Site API Key Manager";
pub const subtitle_zh = "多站点 API Key 管理器";
pub const subtitle_ja = "マルチサイト APIキー マネージャー";

pub const display_sites_path = "~/.velora/sites.json";
pub const display_install_bin_path = "~/.velora/bin";

pub const codex_config_dir = ".codex";
pub const codex_config_filename = "config.toml";
pub const claude_config_dir = ".claude";
pub const claude_settings_filename = "settings.json";
pub const opencode_config_dir_parts = &[_][]const u8{ ".config", "opencode" };
pub const opencode_config_filename = "opencode.json";

pub const github_repo = "MakotoArai-CN/Velora";
pub const github_releases_url = "https://api.github.com/repos/" ++ github_repo ++ "/releases/latest";

pub const install_bin_dir_name = "bin";
pub const path_marker = "# velora PATH";

// Default models per tool type
pub const default_model_cc = "claude-opus-4-6";
pub const default_model_cx = "GPT-5.4";
pub const default_model_oc = "GPT-5.4";

pub fn executableName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => command_name ++ ".exe",
        else => command_name,
    };
}
