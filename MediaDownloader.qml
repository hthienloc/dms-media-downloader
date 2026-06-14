import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import qs.Services
import "./dms-common"

PluginComponent {
    id: root

    pluginId: "mediaDownloader"

    pillRightClickAction: function() {
        Proc.runCommand(
            "mediaDownloader.rightClickPaste",
            ["sh", "-c", "wl-paste --no-newline || xclip -selection clipboard -o"],
            (stdout, exitCode) => {
                if (exitCode === 0 && stdout !== "") {
                    var trimmed = stdout.trim();
                    if (trimmed.indexOf("http://") === 0 || trimmed.indexOf("https://") === 0 || trimmed.indexOf("www.") === 0) {
                        root.activeUrl = trimmed;
                    }
                }
                root.triggerPopout();
            },
            0
        );
    }

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
    property bool hasHistoryItems: false
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
        var activeCount = 0;
        var historyCount = 0;
        for (var i = 0; i < downloadsModel.count; i++) {
            var s = downloadsModel.get(i).status;
            if (s === "fetching" || s === "downloading") {
                activeCount++;
            } else if (s === "completed" || s === "cancelled" || s === "error") {
                historyCount++;
            }
        }
        root.activeDownloadsCount = activeCount;
        root.hasHistoryItems = historyCount > 0;
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
            quality: quality,
            fullPath: ""
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
        delegate: Item {
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
                        args.push("--embed-thumbnail");
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
                            var fullP = dest;
                            if (dest.indexOf("/") !== -1) {
                                dest = dest.substring(dest.lastIndexOf("/") + 1);
                            }
                            downloadsModel.setProperty(index, "title", dest);
                            downloadsModel.setProperty(index, "fullPath", fullP);
                        } else if (line.indexOf("[Merger] Merging formats into") === 0) {
                            var merger = line.substring(30).replace(/"/g, "").trim();
                            var fullM = merger;
                            if (merger.indexOf("/") !== -1) {
                                merger = merger.substring(merger.lastIndexOf("/") + 1);
                            }
                            downloadsModel.setProperty(index, "title", merger);
                            downloadsModel.setProperty(index, "fullPath", fullM);
                        }
                    }
                }

                onExited: (exitCode) => {
                    running = false;
                    if (exitCode === 0) {
                        downloadsModel.setProperty(index, "status", "completed");
                        downloadsModel.setProperty(index, "progress", 100);
                        if (typeof ToastService !== "undefined" && ToastService) {
                            ToastService.showSuccess("Download Completed", downloadsModel.get(index).title || "File downloaded successfully");
                        }
                    } else {
                        if (downloadsModel.get(index).status !== "cancelled") {
                            downloadsModel.setProperty(index, "status", "error");
                            if (typeof ToastService !== "undefined" && ToastService) {
                                ToastService.showError("Download Failed", "Failed to download: " + downloadsModel.get(index).url);
                            }
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



    horizontalBarPill: Component {
        Item {
            implicitWidth: horizontalRow.implicitWidth
            implicitHeight: Theme.iconSize
            anchors.verticalCenter: parent.verticalCenter
            
            property bool draggingOver: false

            Row {
                id: horizontalRow
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                scale: draggingOver ? 1.2 : 1.0
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                DankIcon {
                    name: "download"
                    size: Theme.iconSizeSmall
                    color: draggingOver ? Theme.primary : (root.activeDownloadsCount > 0 ? Theme.primary : Theme.surfaceText)
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.activeDownloadsCount
                    visible: root.activeDownloadsCount > 0
                    color: Theme.primary
                    font.pixelSize: Theme.fontSizeSmall
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            DropArea {
                anchors.fill: parent
                onEntered: draggingOver = true
                onExited: draggingOver = false
                onDropped: (drop) => {
                    draggingOver = false;
                    var urlStr = "";
                    if (drop.hasUrls && drop.urls.length > 0) {
                        urlStr = drop.urls[0].toString();
                    } else if (drop.hasText) {
                        urlStr = drop.text;
                    }
                    urlStr = urlStr.trim();
                    
                    if (urlStr.indexOf("http://") === 0 || urlStr.indexOf("https://") === 0 || urlStr.indexOf("www.") === 0) {
                        root.activeUrl = urlStr;
                        root.triggerPopout();
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: Theme.iconSize
            implicitHeight: verticalCol.implicitHeight
            anchors.horizontalCenter: parent.horizontalCenter
            
            property bool draggingOver: false

            Column {
                id: verticalCol
                spacing: 2
                anchors.horizontalCenter: parent.horizontalCenter
                scale: draggingOver ? 1.2 : 1.0
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                DankIcon {
                    name: "download"
                    size: Theme.iconSizeSmall
                    color: draggingOver ? Theme.primary : (root.activeDownloadsCount > 0 ? Theme.primary : Theme.surfaceText)
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: root.activeDownloadsCount
                    visible: root.activeDownloadsCount > 0
                    color: Theme.primary
                    font.pixelSize: Theme.fontSizeSmall - 2
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            DropArea {
                anchors.fill: parent
                onEntered: draggingOver = true
                onExited: draggingOver = false
                onDropped: (drop) => {
                    draggingOver = false;
                    var urlStr = "";
                    if (drop.hasUrls && drop.urls.length > 0) {
                        urlStr = drop.urls[0].toString();
                    } else if (drop.hasText) {
                        urlStr = drop.text;
                    }
                    urlStr = urlStr.trim();
                    
                    if (urlStr.indexOf("http://") === 0 || urlStr.indexOf("https://") === 0 || urlStr.indexOf("www.") === 0) {
                        root.activeUrl = urlStr;
                        root.triggerPopout();
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
            detailsText: ""

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
                Item {
                    width: parent.width
                    height: Theme.fontSizeSmall + 8

                    StyledText {
                        text: "Downloads Queue"
                        font.weight: Font.Bold
                        font.pixelSize: Theme.fontSizeSmall
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Button {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        height: 20
                        flat: true
                        enabled: root.hasHistoryItems
                        background: Item {}
                        contentItem: Row {
                            spacing: 4
                            opacity: root.hasHistoryItems ? 1.0 : 0.4
                            DankIcon {
                                name: "delete_sweep"
                                size: 14
                                color: root.hasHistoryItems ? Theme.error : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                            StyledText {
                                text: "Clear History"
                                font.pixelSize: Theme.fontSizeSmall - 2
                                color: root.hasHistoryItems ? Theme.error : Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        onClicked: {
                            for (var i = downloadsModel.count - 1; i >= 0; i--) {
                                var s = downloadsModel.get(i).status;
                                if (s === "completed" || s === "cancelled" || s === "error") {
                                    downloadsModel.remove(i);
                                }
                            }
                            root.updateActiveCount();
                        }
                    }
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
                                height: 64
                                color: Theme.surfaceContainerHigh
                                radius: Theme.cornerRadius
                                border.color: Theme.withAlpha(Theme.outline, 0.1)
                                clip: true

                                Column {
                                    anchors.fill: parent
                                    anchors.topMargin: 8
                                    anchors.bottomMargin: 8
                                    anchors.leftMargin: Theme.spacingM
                                    anchors.rightMargin: Theme.spacingM
                                    spacing: 4

                                    Item {
                                        width: parent.width
                                        height: Math.max(titleText.implicitHeight, progressText.implicitHeight)

                                        StyledText {
                                            id: titleText
                                            text: model.title
                                            anchors.left: parent.left
                                            anchors.right: progressText.left
                                            anchors.rightMargin: Theme.spacingM
                                            anchors.verticalCenter: parent.verticalCenter
                                            elide: Text.ElideRight
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                        }
                                        StyledText {
                                            id: progressText
                                            text: model.status === "completed" ? "Done" : (model.status === "error" ? "Error" : (model.status === "cancelled" ? "Cancelled" : model.progress + "%"))
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            font.pixelSize: Theme.fontSizeSmall - 1
                                            color: model.status === "error" ? Theme.error : (model.status === "completed" ? Theme.success : Theme.primary)
                                        }
                                    }

                                    Item {
                                        width: parent.width
                                        height: 24

                                        StyledText {
                                            text: model.status === "downloading" ? model.speed + " - ETA " + model.eta : (model.status === "fetching" ? "Initializing..." : "")
                                            font.pixelSize: Theme.fontSizeSmall - 2
                                            color: Theme.surfaceVariantText
                                            anchors.left: parent.left
                                            anchors.right: actionButtonsRow.left
                                            anchors.rightMargin: Theme.spacingS
                                            elide: Text.ElideRight
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        Row {
                                            id: actionButtonsRow
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 4

                                            // Cancel Button
                                            Button {
                                                width: 24; height: 24
                                                visible: model.status === "downloading" || model.status === "fetching"
                                                flat: true
                                                background: Rectangle {
                                                    color: parent.hovered ? Theme.withAlpha(Theme.error, 0.1) : "transparent"
                                                    radius: 12
                                                }
                                                contentItem: DankIcon {
                                                    name: "close"
                                                    size: 16
                                                    color: Theme.error
                                                    anchors.centerIn: parent
                                                }
                                                onClicked: {
                                                    downloadsModel.setProperty(index, "status", "cancelled");
                                                }
                                            }

                                            // Retry Button
                                            Button {
                                                width: 24; height: 24
                                                visible: model.status === "error" || model.status === "cancelled"
                                                flat: true
                                                background: Rectangle {
                                                    color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"
                                                    radius: 12
                                                }
                                                contentItem: DankIcon {
                                                    name: "refresh"
                                                    size: 16
                                                    color: Theme.primary
                                                    anchors.centerIn: parent
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

                                            // Play Music/Video Button
                                            Button {
                                                width: 24; height: 24
                                                visible: model.status === "completed"
                                                flat: true
                                                background: Rectangle {
                                                    color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"
                                                    radius: 12
                                                }
                                                contentItem: DankIcon {
                                                    name: "play_arrow"
                                                    size: 20
                                                    color: Theme.primary
                                                    anchors.centerIn: parent
                                                }
                                                onClicked: {
                                                    let p = model.fullPath || (root.downloadPath + "/" + model.title);
                                                    Quickshell.execDetached(["xdg-open", p]);
                                                }
                                            }

                                            // Open File Button
                                            Button {
                                                width: 24; height: 24
                                                visible: model.status === "completed"
                                                flat: true
                                                background: Rectangle {
                                                    color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"
                                                    radius: 12
                                                }
                                                contentItem: DankIcon {
                                                    name: "open_in_new"
                                                    size: 18
                                                    color: Theme.primary
                                                    anchors.centerIn: parent
                                                }
                                                onClicked: {
                                                    let p = model.fullPath || (root.downloadPath + "/" + model.title);
                                                    Quickshell.execDetached(["xdg-open", p]);
                                                }
                                            }

                                            // Open Folder Button
                                            Button {
                                                width: 24; height: 24
                                                visible: model.status === "completed"
                                                flat: true
                                                background: Rectangle {
                                                    color: parent.hovered ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"
                                                    radius: 12
                                                }
                                                contentItem: DankIcon {
                                                    name: "folder"
                                                    size: 18
                                                    color: Theme.primary
                                                    anchors.centerIn: parent
                                                }
                                                onClicked: {
                                                    let p = model.fullPath || (root.downloadPath + "/" + model.title);
                                                    let dir = p.substring(0, p.lastIndexOf("/"));
                                                    Quickshell.execDetached(["xdg-open", dir]);
                                                }
                                            }
                                        }
                                    }
                                }

                                // Dynamic Progress Bar (anchored to bottom of the card)
                                Rectangle {
                                    anchors.bottom: parent.bottom
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    height: 4
                                    color: Theme.withAlpha(Theme.surfaceText, 0.1)

                                    Rectangle {
                                        width: parent.width * (model.progress / 100)
                                        height: parent.height
                                        color: model.status === "error" ? Theme.error : (model.status === "completed" ? Theme.success : Theme.primary)
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.RightButton
                                    onClicked: (mouse) => {
                                        if (mouse.button === Qt.RightButton && model.status === "completed") {
                                            root.activeHistoryIndex = index;
                                            historyMenu.open(mouse.x, mouse.y);
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

    property int activeHistoryIndex: -1
    Popup {
        id: historyMenu
        width: 180
        height: menuColumn.implicitHeight + Theme.spacingS * 2
        padding: 0
        background: Rectangle {
            color: "transparent"
        }

        contentItem: StyledRect {
            color: Theme.surfaceContainer
            radius: Theme.cornerRadius
            border.color: Theme.withAlpha(Theme.outline, 0.15)
            border.width: 1

            Column {
                id: menuColumn
                anchors.fill: parent
                anchors.margins: Theme.spacingS
                spacing: 2

                Repeater {
                    model: [
                        {
                            text: I18n.tr("Play Now"),
                            icon: "play_arrow",
                            action: function() {
                                let item = downloadsModel.get(root.activeHistoryIndex);
                                let p = item.fullPath || (root.downloadPath + "/" + item.title);
                                Quickshell.execDetached(["xdg-open", p]);
                            }
                        },
                        {
                            text: I18n.tr("Open File"),
                            icon: "open_in_new",
                            action: function() {
                                let item = downloadsModel.get(root.activeHistoryIndex);
                                let p = item.fullPath || (root.downloadPath + "/" + item.title);
                                Quickshell.execDetached(["xdg-open", p]);
                            }
                        },
                        {
                            text: I18n.tr("Open Folder"),
                            icon: "folder",
                            action: function() {
                                let item = downloadsModel.get(root.activeHistoryIndex);
                                let p = item.fullPath || (root.downloadPath + "/" + item.title);
                                let dir = p.substring(0, p.lastIndexOf("/"));
                                Quickshell.execDetached(["xdg-open", dir]);
                            }
                        },
                        {
                            text: I18n.tr("Remove from History"),
                            icon: "delete",
                            action: function() {
                                downloadsModel.remove(root.activeHistoryIndex);
                                root.updateActiveCount();
                            }
                        }
                    ]

                    delegate: MouseArea {
                        width: parent.width
                        height: 32
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        Rectangle {
                            anchors.fill: parent
                            color: parent.containsMouse ? Theme.withAlpha(Theme.primary, 0.1) : "transparent"
                            radius: Theme.cornerRadiusSmall
                        }

                        Row {
                            anchors.fill: parent
                            anchors.leftMargin: Theme.spacingS
                            anchors.rightMargin: Theme.spacingS
                            spacing: Theme.spacingS

                            DankIcon {
                                name: modelData.icon
                                size: 16
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: modelData.text
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceText
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        onClicked: {
                            modelData.action();
                            historyMenu.close();
                        }
                    }
                }
            }
        }
    }
}
