import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "./dms-common"

PluginSettings {
    id: root

    pluginId: "mediaDownloader"

    PluginHeader {
        title: "Media Downloader Settings"
        description: "Configure your download location, quality presets, and yt-dlp parameters."
    }

    SettingsCard {
        SectionTitle {
            text: "General Settings"
            icon: "settings"
        }

        StringSettingPlus {
            settingKey: "downloadPath"
            label: "Download Folder"
            description: "Directory where files will be saved."
            defaultValue: Quickshell.env("HOME") + "/Downloads"
            isDirectory: true
        }
    }

    SettingsCard {
        SectionTitle {
            text: "Quick Video Defaults"
            icon: "videocam"
        }

        SelectionSettingPlus {
            settingKey: "quickVideoFormat"
            label: "Preferred Format"
            description: "Format for Quick Video downloads."
            defaultValue: "mp4"
            options: [
                { label: "MP4 (Compatible)", value: "mp4" },
                { label: "WebM (Open Format)", value: "webm" }
            ]
        }

        SelectionSettingPlus {
            settingKey: "quickVideoRes"
            label: "Max Resolution"
            description: "Maximum resolution for Quick Video downloads."
            defaultValue: "1080p"
            options: [
                { label: "Best Available Quality", value: "best" },
                { label: "1080p (Full HD)", value: "1080p" },
                { label: "720p (HD)", value: "720p" },
                { label: "480p (SD)", value: "480p" }
            ]
        }
    }

    SettingsCard {
        SectionTitle {
            text: "Quick Audio Defaults"
            icon: "audiotrack"
        }

        SelectionSettingPlus {
            settingKey: "quickAudioFormat"
            label: "Preferred Audio Format"
            description: "Format for Quick Audio downloads."
            defaultValue: "mp3"
            options: [
                { label: "MP3 (Most Compatible)", value: "mp3" },
                { label: "Opus (Low Bitrate efficient)", value: "opus" },
                { label: "FLAC (Lossless)", value: "flac" },
                { label: "WAV (Uncompressed)", value: "wav" }
            ]
        }

        SelectionSettingPlus {
            settingKey: "quickAudioQuality"
            label: "Audio Quality"
            description: "Target bitrate or quality tier."
            defaultValue: "best"
            options: [
                { label: "Best Available Quality", value: "best" },
                { label: "320 kbps (High Quality)", value: "320k" },
                { label: "192 kbps (Medium Quality)", value: "192k" },
                { label: "128 kbps (Low Quality)", value: "128k" }
            ]
        }
    }

    SettingsCard {
        SectionTitle {
            text: "Advanced Downloader Settings"
            icon: "tune"
        }

        ToggleSettingPlus {
            settingKey: "sponsorBlock"
            label: "Enable SponsorBlock"
            description: "Automatically skip sponsor blocks in YouTube videos."
            defaultValue: true
        }

        ToggleSettingPlus {
            settingKey: "embedThumbnail"
            label: "Embed Thumbnail"
            description: "Embed video or audio thumbnail as cover art."
            defaultValue: true
        }

        ToggleSettingPlus {
            settingKey: "embedMetadata"
            label: "Embed Metadata"
            description: "Write metadata tags (title, artist, etc.) to the output file."
            defaultValue: true
        }

        ToggleSettingPlus {
            settingKey: "embedSubs"
            label: "Embed Subtitles"
            description: "Download and embed subtitles into video files."
            defaultValue: false
        }

        ToggleSettingPlus {
            id: limitToggle
            settingKey: "limitRate"
            label: "Limit Download Speed"
            description: "Throttle downloads to prevent network congestion."
            defaultValue: false
        }

        SliderSettingPlus {
            settingKey: "maxRate"
            label: "Max Speed Limit"
            description: "Speed limit when throttling is enabled."
            defaultValue: 5000
            minimum: 500
            maximum: 50000
            unit: " KB/s"
            enabled: limitToggle.value
        }
    }
}
