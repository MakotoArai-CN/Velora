const builtin = @import("builtin");

pub const display_name = "avm";
pub const command_name = "avm";
pub const config_dir_name = ".avm";
pub const legacy_config_dir_name = ".velora";
pub const sites_filename = "sites.json";

pub const subtitle_en = "Multi-Site API Key Manager";
pub const subtitle_zh = "多站点 API Key 管理器";
pub const subtitle_ja = "マルチサイト APIキー マネージャー";

pub const display_sites_path = "~/.avm/sites.json";
pub const display_install_bin_path = "~/.avm/bin";

pub const codex_config_dir = ".codex";
pub const codex_config_filename = "config.toml";
pub const claude_config_dir = ".claude";
pub const claude_settings_filename = "settings.json";
pub const opencode_config_dir_parts = &[_][]const u8{ ".config", "opencode" };
pub const opencode_config_filename = "opencode.json";

// Nanobot config
pub const nanobot_config_dir = ".nanobot";
pub const nanobot_config_filename = "config.json";

// OpenClaw config
pub const openclaw_config_dir = ".openclaw";
pub const openclaw_config_filename = "openclaw.json";

pub const github_repo = "MakotoArai-CN/avm";
pub const github_releases_url = "https://api.github.com/repos/" ++ github_repo ++ "/releases/latest";

pub const install_bin_dir_name = "bin";
pub const path_marker = "# avm PATH";
pub const legacy_path_marker = "# velora PATH";
pub const openclaw_provider_name = "avm";
pub const legacy_openclaw_provider_name = "velora";
pub const openclaw_provider_names = [_][]const u8{ openclaw_provider_name, legacy_openclaw_provider_name };

// Default models per tool type
pub const default_model_cc = "claude-opus-4-6";
pub const default_model_cx = "gpt-5.4";
pub const default_model_oc = "gpt-5.4";
pub const default_model_nb = "gpt-5.4";
pub const default_model_ow = "gpt-5.4";

pub fn executableName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => command_name ++ ".exe",
        else => command_name,
    };
}
