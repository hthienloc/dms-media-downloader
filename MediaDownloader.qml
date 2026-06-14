import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Services

PluginComponent {
    id: root

    pluginId: "mediaDownloader"
    property var popoutService: null

    // Read settings
    readonly property string downloadPath: pluginData.downloadPath ?? (Quickshell.env("HOME") + "/Downloads")
    readonly property string quickVideoFormat: pluginData.quickVideoFormat ?? "mp4"
    readonly property string quickVideoRes: pluginData.quickVideoRes ?? "1080p"
    readonly property string quickAudioFormat: pluginData.quickAudioFormat ?? "mp3"
    readonly property string quickAudioQuality: pluginData.quickAudioQuality ?? "best"
    readonly property bool sponsorBlock: pluginData.sponsorBlock ?? true
    readonly property bool limitRate: pluginData.limitRate ?? false
    readonly property int maxRate: pluginData.maxRate ?? 5000

    // State variables
    property string activeUrl: ""
    property int activeDownloadsCount: 0
    property string customMode: "" // "", "video", "audio"

    // Custom configuration states
    property string customFormat: ""
    property string customQuality: ""

    // ListModel for tracking downloads
    ListModel {
        id: downloadsModel
    }

    // Update active count whenever model changes
    function updateActiveCount() {
        var count = 0;
        for (var i = 0; i < downloadsModel.count; i++) {
            var s = downloadsModel.get(i).status;
            if (s === "fetching" || s === "downloading") {
                count++;
            }
        }
        root.activeDownloadsCount = count;
    }

    // Helper functions for formatting bytes and speed
    function formatSpeed(speedBytes) {
        var bytes = parseFloat(speedBytes);
        if (isNaN(bytes) || bytes <= 0) return "0 B/s";
        var k = 1024;
        var sizes = ["B/s", "KB/s", "MB/s", "GB/s"];
        var i = Math.floor(Math.log(bytes) / Math.log(k));
        return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + " " + sizes[i];
    }

    function formatEta(seconds) {
        var sec = parseInt(seconds);
        if (isNaN(sec) || sec <= 0) return "00:00";
        var h = Math.floor(sec / 3600);
        var m = Math.floor((sec % 3600) / 60);
        var s = sec % 60;
        var pad = (n) => n < 10 ? "0" + n : n;
        if (h > 0) return pad(h) + ":" + pad(m) + ":" + pad(s);
        return pad(m) + ":" + pad(s);
    }

    // Function to add and start a download process
    function startDownload(url, type, format, quality) {
        downloadsModel.append({
            url: url,
            title: "Fetching title...",
            progress: 0,
            speed: "0 B/s",
            eta: "--:--",
            status: "fetching",
            type: type,
            format: format,
            quality: quality
        });
        
        var idx = downloadsModel.count - 1;
        updateActiveCount();

        // Get the title first via a quick shell query
        Proc.runCommand("mediaDownloader.getTitle_" + idx, ["yt-dlp", "--ignore-config", "--get-title", url], (stdout, exitCode) => {
            if (exitCode === 0 && stdout.trim().length > 0) {
                downloadsModel.setProperty(idx, "title", stdout.trim());
            } else {
                downloadsModel.setProperty(idx, "title", url);
            }
            downloadsModel.setProperty(idx, "status", "downloading");
            updateActiveCount();
        });
    }

    // Instantiator for active download processes
    Instantiator {
        model: downloadsModel
        delegate: QtObject {
            property bool isDownloading: model.status === "downloading"
            
            property Process downloadProc: Process {
                running: isDownloading
                command: {
                    var args = [
                        "yt-dlp",
                        "--ignore-config",
                        "--newline",
                        "--progress",
                        "--progress-template", "[Progress];%(progress.status)s;%(progress.downloaded_bytes)s;%(progress.total_bytes)s;%(progress.total_bytes_estimate)s;%(progress.speed)s;%(progress.eta)s",
                        "--paths", root.downloadPath,
                        "--output", "%(title)s.%(ext)s"
                    ];

                    if (model.type === "audio") {
                        args.push("-x");
                        args.push("--audio-format");
                        args.push(model.format);
                        if (model.quality !== "best") {
                            args.push("--audio-quality");
                            args.push(model.quality);
                        }
                    } else {
                        args.push("-f");
                        if (model.quality === "best") {
                            args.push("bestvideo+bestaudio/best");
                        } else {
                            var res = model.quality.replace("p", "");
                            args.push("bestvideo[height<=" + res + "]+bestaudio/best[height<=" + res + "]");
                        }
                        args.push("--merge-output-format");
                        args.push(model.format);
                    }

                    if (root.sponsorBlock) {
                        args.push("--sponsorblock-remove");
                        args.push("default");
                    }
                    if (root.limitRate) {
                        args.push("--limit-rate");
                        args.push(root.maxRate + "K");
                    }

                    args.push(model.url);
                    return args;
                }

                stdout: SplitParser {
                    onRead: (data) => {
                        var line = String(data).trim();
                        if (line.indexOf("[Progress];") === 0) {
                            var parts = line.split(";");
                            var status = parts[1];
                            var downloadedBytes = parseInt(parts[2]) || 0;
                            var totalBytes = parseInt(parts[3]) || parseInt(parts[4]) || 0;
                            var speed = parts[5];
                            var eta = parts[6];
                            
                            var percent = totalBytes > 0 ? Math.round((downloadedBytes / totalBytes) * 100) : 0;
                            
                            downloadsModel.setProperty(index, "progress", percent);
                            downloadsModel.setProperty(index, "speed", root.formatSpeed(speed));
                            downloadsModel.setProperty(index, "eta", root.formatEta(eta));
                        } else if (line.indexOf("[download] Destination:") === 0) {
                            var dest = line.substring(23).trim();
                            if (dest.indexOf("/") !== -1) {
                                dest = dest.substring(dest.lastIndexOf("/") + 1);
                            }
                            downloadsModel.setProperty(index, "title", dest);
                        } else if (line.indexOf("[Merger] Merging formats into") === 0) {
                            var merger = line.substring(30).replace(/"/g, "").trim();
                            if (merger.indexOf("/") !== -1) {
                                merger = merger.substring(merger.lastIndexOf("/") + 1);
                            }
                            downloadsModel.setProperty(index, "title", merger);
                        }
                    }
                }

                onExited: (exitCode) => {
                    running = false;
                    if (exitCode === 0) {
                        downloadsModel.setProperty(index, "status", "completed");
                        downloadsModel.setProperty(index, "progress", 100);
                        ToastService?.showSuccess("Download Completed", downloadsModel.get(index).title || "File downloaded successfully");
                    } else {
                        if (downloadsModel.get(index).status !== "cancelled") {
                            downloadsModel.setProperty(index, "status", "error");
                            ToastService?.showError("Download Failed", "Failed to download: " + downloadsModel.get(index).url);
                        }
                    }
                    root.updateActiveCount();
                }
            }

            // Watcher to handle cancellation
            Connections {
                target: downloadsModel
                function onDataChanged(topLeft, bottomRight, roles) {
                    if (topLeft.row <= index && index <= bottomRight.row) {
                        var item = downloadsModel.get(index);
                        if (item.status === "cancelled" && downloadProc.running) {
                            downloadProc.running = false;
                            root.updateActiveCount();
                        }
                    }
                }
            }
        }
    }

    pillClickAction: function() {
        popoutService.togglePopout(root);
    }

    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingS

            DankIcon {
                name: "download"
                size: Theme.iconSizeSmall
                color: root.activeDownloadsCount > 0 ? Theme.primary : Theme.surfaceText
            }

            StyledText {
                text: root.activeDownloadsCount > 0 ? "Downloading (" + root.activeDownloadsCount + ")" : "Downloader"
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            DropArea {
                anchors.fill: parent
                onEntered: (drag) => {
                    if (drag.hasText || drag.hasUrls) {
                        drag.acceptProposedAction();
                    }
                }
                onDropped: (drop) => {
                    var urlStr = "";
                    if (drop.hasUrls && drop.urls.length > 0) {
                        urlStr = String(drop.urls[0]);
                    } else if (drop.hasText) {
                        urlStr = drop.text;
                    }
                    
                    if (urlStr.indexOf("http://") === 0 || urlStr.indexOf("https://") === 0 || urlStr.indexOf("www.") === 0) {
                        root.activeUrl = urlStr;
                        popoutService.openPopout(root);
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            anchors.horizontalCenter: parent.horizontalCenter

            DankIcon {
                name: "download"
                size: Theme.iconSizeSmall
                color: root.activeDownloadsCount > 0 ? Theme.primary : Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: root.activeDownloadsCount > 0 ? String(root.activeDownloadsCount) : "DL"
                font.pixelSize: Theme.fontSizeSmall - 1
                font.weight: Font.Medium
                color: Theme.surfaceText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            DropArea {
                anchors.fill: parent
                onEntered: (drag) => {
                    if (drag.hasText || drag.hasUrls) {
                        drag.acceptProposedAction();
                    }
                }
                onDropped: (drop) => {
                    var urlStr = "";
                    if (drop.hasUrls && drop.urls.length > 0) {
                        urlStr = String(drop.urls[0]);
                    } else if (drop.hasText) {
                        urlStr = drop.text;
                    }
                    
                    if (urlStr.indexOf("http://") === 0 || urlStr.indexOf("https://") === 0 || urlStr.indexOf("www.") === 0) {
                        root.activeUrl = urlStr;
                        popoutService.openPopout(root);
                    }
                }
            }
        }
    }

    // Popout Dialog Layout
    popoutWidth: 380
    popoutHeight: 460

    popoutContent: Component {
        PopoutComponent {
            id: popoutComp
            headerText: "Media Downloader"
            detailsText: "Paste a URL or drop a link to start"

            Column {
                width: parent.width
                spacing: Theme.spacingM

                // URL Input Field
                DankTextField {
                    id: urlInput
                    width: parent.width
                    placeholderText: "Paste video or audio link here..."
                    text: root.activeUrl
                    onTextChanged: {
                        root.activeUrl = text;
                        if (text.length === 0) {
                            root.customMode = "";
                        }
                    }
                }

                // Grid of 4 download options (when URL is loaded)
                Grid {
                    width: parent.width
                    columns: 2
                    spacing: Theme.spacingM
                    visible: root.activeUrl.length > 0

                    // Option 1: Quick Video
                    Button {
                        width: (parent.width - Theme.spacingM) / 2
                        height: 54
                        background: Rectangle {
                            color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.15) : Theme.surfaceContainerHigh
                            border.color: parent.hovered ? Theme.primary : Theme.withAlpha(Theme.outline, 0.2)
                            radius: Theme.cornerRadius
                        }
                        contentItem: Column {
                            spacing: 2
                            anchors.centerIn: parent
                            Row {
                                spacing: 4
                                anchors.horizontalCenter: parent.horizontalCenter
                                DankIcon { name: "videocam"; size: 16; color: Theme.primary }
                                StyledText { text: "Quick Video"; font.weight: Font.Bold; font.pixelSize: Theme.fontSizeSmall }
                            }
                            StyledText { 
                                text: root.quickVideoRes + " (" + root.quickVideoFormat.toUpperCase() + ")"
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                        onClicked: {
                            root.startDownload(root.activeUrl, "video", root.quickVideoFormat, root.quickVideoRes);
                            root.activeUrl = "";
                            urlInput.text = "";
                        }
                    }

                    // Option 2: Quick Audio
                    Button {
                        width: (parent.width - Theme.spacingM) / 2
                        height: 54
                        background: Rectangle {
                            color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.15) : Theme.surfaceContainerHigh
                            border.color: parent.hovered ? Theme.primary : Theme.withAlpha(Theme.outline, 0.2)
                            radius: Theme.cornerRadius
                        }
                        contentItem: Column {
                            spacing: 2
                            anchors.centerIn: parent
                            Row {
                                spacing: 4
                                anchors.horizontalCenter: parent.horizontalCenter
                                DankIcon { name: "audiotrack"; size: 16; color: Theme.primary }
                                StyledText { text: "Quick Audio"; font.weight: Font.Bold; font.pixelSize: Theme.fontSizeSmall }
                            }
                            StyledText { 
                                text: root.quickAudioFormat.toUpperCase() + " (" + root.quickAudioQuality + ")"
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                        onClicked: {
                            root.startDownload(root.activeUrl, "audio", root.quickAudioFormat, root.quickAudioQuality);
                            root.activeUrl = "";
                            urlInput.text = "";
                        }
                    }

                    // Option 3: Custom Video Options
                    Button {
                        width: (parent.width - Theme.spacingM) / 2
                        height: 54
                        background: Rectangle {
                            color: root.customMode === "video" ? Theme.withAlpha(Theme.primary, 0.2) : (parent.hovered ? Theme.withAlpha(Theme.primary, 0.15) : Theme.surfaceContainerHigh)
                            border.color: root.customMode === "video" || parent.hovered ? Theme.primary : Theme.withAlpha(Theme.outline, 0.2)
                            radius: Theme.cornerRadius
                        }
                        contentItem: Column {
                            spacing: 2
                            anchors.centerIn: parent
                            Row {
                                spacing: 4
                                anchors.horizontalCenter: parent.horizontalCenter
                                DankIcon { name: "settings"; size: 16; color: Theme.primary }
                                StyledText { text: "Custom Video"; font.weight: Font.Bold; font.pixelSize: Theme.fontSizeSmall }
                            }
                            StyledText { 
                                text: "Select quality & format"
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                        onClicked: {
                            root.customMode = "video";
                            root.customFormat = "mp4";
                            root.customQuality = "1080p";
                        }
                    }

                    // Option 4: Custom Audio Options
                    Button {
                        width: (parent.width - Theme.spacingM) / 2
                        height: 54
                        background: Rectangle {
                            color: root.customMode === "audio" ? Theme.withAlpha(Theme.primary, 0.2) : (parent.hovered ? Theme.withAlpha(Theme.primary, 0.15) : Theme.surfaceContainerHigh)
                            border.color: root.customMode === "audio" || parent.hovered ? Theme.primary : Theme.withAlpha(Theme.outline, 0.2)
                            radius: Theme.cornerRadius
                        }
                        contentItem: Column {
                            spacing: 2
                            anchors.centerIn: parent
                            Row {
                                spacing: 4
                                anchors.horizontalCenter: parent.horizontalCenter
                                DankIcon { name: "settings"; size: 16; color: Theme.primary }
                                StyledText { text: "Custom Audio"; font.weight: Font.Bold; font.pixelSize: Theme.fontSizeSmall }
                            }
                            StyledText { 
                                text: "Select format & bitrate"
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: Theme.surfaceVariantText
                                anchors.horizontalCenter: parent.horizontalCenter
                            }
                        }
                        onClicked: {
                            root.customMode = "audio";
                            root.customFormat = "mp3";
                            root.customQuality = "best";
                        }
                    }
                }

                // Placeholder when URL is empty
                StyledText {
                    text: "Copy a link and drop it onto the download pill on the bar, or paste it here to choose options."
                    width: parent.width
                    wrapMode: Text.WordWrap
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    horizontalAlignment: Text.AlignHCenter
                    visible: root.activeUrl.length === 0
                    height: 54
                }

                // Custom Configuration Subpanels
                Column {
                    width: parent.width
                    spacing: Theme.spacingS
                    visible: root.customMode !== ""

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        // Format Combo
                        Column {
                            width: (parent.width - Theme.spacingM) / 2
                            spacing: 2
                            StyledText { text: "Format"; font.pixelSize: Theme.fontSizeSmall - 1 }
                            ComboBox {
                                width: parent.width
                                model: root.customMode === "video" ? ["mp4", "webm"] : ["mp3", "opus", "flac", "wav"]
                                currentIndex: 0
                                onCurrentTextChanged: root.customFormat = currentText
                            }
                        }

                        // Quality Combo
                        Column {
                            width: (parent.width - Theme.spacingM) / 2
                            spacing: 2
                            StyledText { text: "Quality"; font.pixelSize: Theme.fontSizeSmall - 1 }
                            ComboBox {
                                width: parent.width
                                model: root.customMode === "video" ? ["best", "1080p", "720p", "480p"] : ["best", "320k", "192k", "128k"]
                                currentIndex: 0
                                onCurrentTextChanged: root.customQuality = currentText
                            }
                        }
                    }

                    Button {
                        width: parent.width
                        height: 36
                        text: "Start Custom Download"
                        background: Rectangle {
                            color: parent.hovered ? Theme.primary : Theme.withAlpha(Theme.primary, 0.8)
                            radius: Theme.cornerRadius
                        }
                        onClicked: {
                            root.startDownload(root.activeUrl, root.customMode, root.customFormat, root.customQuality);
                            root.activeUrl = "";
                            root.customMode = "";
                            urlInput.text = "";
                        }
                    }
                }

                Separator {}

                // Active / Past Downloads List
                StyledText {
                    text: "Downloads Queue"
                    font.weight: Font.Bold
                    font.pixelSize: Theme.fontSizeSmall
                }

                ScrollView {
                    width: parent.width
                    height: root.customMode !== "" ? 120 : 200
                    clip: true

                    Column {
                        width: parent.width
                        spacing: Theme.spacingM

                        Repeater {
                            model: downloadsModel
                            delegate: Rectangle {
                                width: parent.width
                                height: 50
                                color: Theme.surfaceContainerHigh
                                radius: Theme.cornerRadius
                                border.color: Theme.withAlpha(Theme.outline, 0.1)

                                Column {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingS
                                    spacing: 4

                                    Row {
                                        width: parent.width
                                        StyledText {
                                            text: model.title
                                            width: parent.width - 80
                                            elide: Text.ElideRight
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                        }
                                        StyledText {
                                            text: model.status === "completed" ? "Done" : (model.status === "error" ? "Error" : (model.status === "cancelled" ? "Cancelled" : model.progress + "%"))
                                            width: 80
                                            horizontalAlignment: Text.AlignRight
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: model.status === "error" ? Theme.error : (model.status === "completed" ? Theme.success : Theme.primary)
                                        }
                                    }

                                    // Dynamic Progress Bar
                                    Rectangle {
                                        width: parent.width
                                        height: 6
                                        color: Theme.withAlpha(Theme.surfaceText, 0.1)
                                        radius: 3
                                        clip: true

                                        Rectangle {
                                            width: parent.width * (model.progress / 100)
                                            height: parent.height
                                            color: model.status === "error" ? Theme.error : (model.status === "completed" ? Theme.success : Theme.primary)
                                            radius: 3
                                        }
                                    }

                                    Row {
                                        width: parent.width
                                        StyledText {
                                            text: model.status === "downloading" ? model.speed + " - ETA " + model.eta : (model.status === "fetching" ? "Initializing..." : "")
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                            color: Theme.surfaceVariantText
                                            width: parent.width - 32
                                        }
                                        
                                        // Cancel Button
                                        Button {
                                            width: 16
                                            height: 16
                                            visible: model.status === "downloading" || model.status === "fetching"
                                            anchors.verticalCenter: parent.verticalCenter
                                            background: Item {}
                                            contentItem: DankIcon {
                                                name: "close"
                                                size: 14
                                                color: Theme.error
                                            }
                                            onClicked: {
                                                downloadsModel.setProperty(index, "status", "cancelled");
                                            }
                                        }

                                        // Retry Button
                                        Button {
                                            width: 16
                                            height: 16
                                            visible: model.status === "error" || model.status === "cancelled"
                                            anchors.verticalCenter: parent.verticalCenter
                                            background: Item {}
                                            contentItem: DankIcon {
                                                name: "refresh"
                                                size: 14
                                                color: Theme.primary
                                            }
                                            onClicked: {
                                                downloadsModel.setProperty(index, "status", "fetching");
                                                downloadsModel.setProperty(index, "progress", 0);
                                                downloadsModel.setProperty(index, "speed", "0 B/s");
                                                downloadsModel.setProperty(index, "eta", "--:--");
                                                root.startDownload(model.url, model.type, model.format, model.quality);
                                                downloadsModel.remove(index);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
