import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Settings UI for irface. The lock screen itself is a patch to the first-party
// omarchy.lock plugin and cannot live here: only one process may hold a
// Wayland session lock, so a second plugin owning the surface would fight it.
// This panel is the control plane for that patch -- enroll a face, turn face
// unlock on and off, and see what the daemon is doing.
Panel {
    id: root
    moduleName: "user.irface"
    ipcTarget: "user.irface"
    manageIpc: false

    // --- state, all of it polled from the shell ---------------------------
    // Read-only facts about the world: whether the daemon is up, whether a
    // template is enrolled, whether the lock patch is applied.
    property bool daemonActive: false
    property bool enrolled: false
    property bool patchApplied: false
    property string lastMessage: ""
    property bool busy: false
    property int capturePercent: 0
    property string captureStatus: ""
    property bool capturing: false

    // The enrolled user, needed for enroll and for the template check. The
    // daemon reads it from the environment, so this is the same account the
    // bar and the shell run as.
    readonly property string targetUser: Quickshell.env("USER") || "mofongo"
    // Substituted with this checkout's absolute path by install.sh. The shell
    // does not pass the installer environment through to plugins, so baking it
    // in is what lets the panel find enroll.sh and reapply.sh. A plugin copied
    // by hand keeps the placeholder and the panel says so instead of guessing.
    readonly property string projectDir: "@IRFACE_DIR@"
    readonly property string enrollScript: projectDir + "/enroll.sh"
    readonly property string reapplyScript: projectDir + "/omarchy-patch/reapply.sh"
    // True when install.sh has not substituted the path, i.e. the plugin was
    // copied into the plugins dir by hand. Better to say so than to run
    // "/omarchy-patch/reapply.sh" and fail confusingly.
    readonly property bool pathResolved: projectDir.length > 1 && projectDir[0] === "/"
    // Set when the post-update hook logged that it could not restore the patch
    // because upstream changed. That is a different problem from "off" and the
    // fix is different too, so it gets its own message rather than looking like
    // the user toggled it off.
    property bool reapplyBlocked: false

    readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
    readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

    // A short glyph in the bar: a face when enrolled, a question mark when not.
    readonly property string barText: root.enrolled ? "\u25CF" : "\u25CB"

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    // --- refresh ----------------------------------------------------------
    // One bash call collects every fact at once rather than three Process
    // blocks racing each other, so the panel can never show a mix of old and
    // new state.
    function refresh() {
        if (statusProc.running) return
        // Plain space-separated words, not JSON. An earlier version emitted
        // yes/no and parsed it with JSON.parse, which throws on bare yes: the
        // whole status silently fell back to all-false. Splitting on
        // whitespace has no quoting to get wrong and cannot half-parse.
        // The template path interpolates the user here rather than referencing
        // a shell variable, because the child bash never has $user set.
        var u = root.targetUser
        statusProc.command = ["bash", "-c",
            'systemctl is-active --quiet irface.service && echo -n "1" || echo -n "0"; echo; ' +
            '[[ -f "$HOME/.local/share/irface/faces/' + u + '.npy" ]] && echo -n "1" || echo -n "0"; echo; ' +
            'grep -q irface /usr/share/omarchy/shell/plugins/lock/Service.qml 2>/dev/null && echo -n "1" || echo -n "0"; echo; ' +
            // 4th field: has the post-update hook ever reported that it could
            // not restore the patch? grep for the marker line it writes.
            'grep -q "face unlock NOT restored" "$HOME/.cache/irface/update.log" 2>/dev/null && echo -n "1" || echo -n "0"']
        statusProc.running = true
    }

    // Called from the collector's onStreamFinished, so `output` is the whole
    // accumulated stdout. It used to read a bare `stdout` identifier here,
    // which is not in scope outside the collector, so this threw on every tick
    // and the panel sat at all-false forever with no visible error.
    function onExited(output) {
        var parts = ((output || "").match(/[01]/g) || [])
        if (parts.length < 4) {
            root.lastMessage = "could not read status"
            return
        }
        root.daemonActive = parts[0] === "1"
        root.enrolled = parts[1] === "1"
        root.patchApplied = parts[2] === "1"
        root.reapplyBlocked = parts[3] === "1"
    }

    // --- actions ----------------------------------------------------------
    // Enabling/disabling is the lock patch, not the daemon: the daemon is
    // harmless when idle (it opens no camera and holds no timer) and sudo auth
    // should keep working whether or not the lock screen uses it. So "off"
    // means "revert the lock files", which is also how you recover from a bad
    // patch without uninstalling.
    function setEnabled(enabled) {
        if (root.busy) return
        root.busy = true
        root.lastMessage = enabled ? "enabling…" : "disabling…"
        var script = root.reapplyScript
        if (!root.pathResolved) {
            root.busy = false
            root.lastMessage = "set IRFACE_DIR to the checkout path"
            return
        }
        toggleProc.command = ["bash", "-c",
            enabled ? script + " 2>&1" : script + " --revert 2>&1"]
        toggleProc.running = true
    }

    function onToggleExited(output) {
        root.busy = false
        root.lastMessage = (output || "").trim().split("\n").pop() || "done"
        root.refresh()
    }

    // Enrollment is slow (20 samples) and needs the camera, so it runs in the
    // background. Progress is read from its stdout rather than a status file:
    // irface/enroll.py already prints "sample N/M", and adding a file just to
    // duplicate that would be another piece of state to keep in sync.
    property string enrollOutput: ""
    property int enrollSamples: 20

    function enroll() {
        if (root.busy) return
        root.busy = true
        root.capturing = true
        root.capturePercent = 0
        root.captureStatus = "starting…"
        root.lastMessage = ""
        root.enrollOutput = ""
        var script = root.enrollScript
        if (!root.pathResolved) {
            root.busy = false
            root.capturing = false
            root.lastMessage = "set IRFACE_DIR to the checkout path"
            return
        }
        enrollProc.command = ["bash", "-c",
            script + " -u " + root.targetUser + " --overwrite 2>&1"]
        enrollProc.running = true
    }

    // Quickshell's StdioCollector delivers the whole accumulated buffer on every
    // chunk, so re-parse it and take the highest sample count seen rather than
    // assuming each callback is a delta. Enrollment prints
    // "  sample 7/20  det=0.93".
    function onEnrollOutput() {
        root.enrollOutput = (text || "").slice(-4000)
        var re = /sample\s+(\d+)\s*\/\s*(\d+)/g
        var m, best = 0
        while ((m = re.exec(root.enrollOutput)) !== null) {
            best = Math.max(best, parseInt(m[1]))
            root.enrollSamples = parseInt(m[2])
        }
        if (best > 0) {
            root.capturePercent = Math.round(100 * best / root.enrollSamples)
            root.captureStatus = "capturing " + best + "/" + root.enrollSamples
        }
    }

    function onEnrollExited(code) {
        root.busy = false
        root.capturing = false
        root.captureStatus = ""
        root.lastMessage = code === 0
            ? "enrolled — lock the screen and look"
            : "enrollment failed"
        root.enrollOutput = ""
        root.refresh()
    }

    function removeTemplate() {
        if (root.busy) return
        removeProc.command = ["bash", "-c",
            'rm -f "$HOME/.local/share/irface/faces/"' + root.targetUser + '".npy"']
        removeProc.running = true
    }

    function onRemoveExited() {
        root.lastMessage = "face template deleted"
        root.refresh()
    }

    // --- keyboard navigation ---------------------------------------------
    property string focusSection: "status"
    property int selectedIndex: -1
    readonly property var sections: ["status", "enable", "enroll", "forget"]
    property bool cursorActive: false

    function sectionCount(section) { return 0 }
    function sectionIsSingleRow(section) { return true }
    function sectionFirstIndex(section) { return -1 }

    function moveCursor(delta) {
        var s = root.sections
        if (!s || s.length === 0) return
        var i = s.indexOf(root.focusSection)
        if (i < 0) { root.focusSection = s[0]; root.selectedIndex = -1; return }
        if (delta > 0 && i < s.length - 1) { root.focusSection = s[i + 1]; root.selectedIndex = -1 }
        else if (delta < 0 && i > 0) { root.focusSection = s[i - 1]; root.selectedIndex = -1 }
    }

    function adjustBrightness() { }  // not a slider
    function clampCursor() {
        if (root.sections.indexOf(root.focusSection) < 0) root.focusSection = root.sections[0]
    }

    function activateCursor() {
        if (!root.cursorActive) return
        switch (root.focusSection) {
        case "enable": root.setEnabled(!root.patchApplied); break
        case "enroll": if (root.daemonActive) root.enroll(); else root.lastMessage = "daemon is not running"; break
        case "forget": root.removeTemplate(); break
        }
    }

    IpcHandler {
        target: "user.irface"
        function open() { root.open() }
        function close() { root.close() }
        function toggle() { root.toggle() }
        function show() { root.open() }
        function hide() { root.close() }
        function refresh() { root.refresh(); return "refreshing" }
        function status(): string {
            return JSON.stringify({
                daemon: root.daemonActive, enrolled: root.enrolled,
                patch: root.patchApplied, busy: root.busy,
                reapplyBlocked: root.reapplyBlocked
            })
        }
        function enable(): string { root.setEnabled(true); return "enabling" }
        function disable(): string { root.setEnabled(false); return "disabling" }
        function enroll(): string { root.enroll(); return "enrolling" }
    }

    Process {
        id: statusProc
        // Read the collector via onExited + stdout.text, which is the pattern
        // the other installed plugin uses. onStreamFinished did not fire here
        // for a short-lived process, so the handler never ran and the panel sat
        // at all-false with no error to explain it.
        stdout: StdioCollector { waitForEnd: true }
        onExited: function(code) { root.onExited(stdout.text) }
    }
    Process {
        id: toggleProc
        stdout: StdioCollector { waitForEnd: true }
        onExited: function(code) { root.onToggleExited(stdout.text) }
    }
    // No waitForEnd: enrollment prints progress as it goes, and we want each
    // chunk while the process is still alive. waitForEnd would withhold
    // everything until exit and leave the progress bar frozen at zero for the
    // whole ~20s capture, which is the one thing it exists to avoid.
    Process {
        id: enrollProc
        onExited: function(code, exitStatus) { root.onEnrollExited(code) }
        stdout: StdioCollector {
            onStreamFinished: root.onEnrollOutput()
        }
    }
    Process {
        id: removeProc
        stdout: StdioCollector { waitForEnd: true }
        onExited: function(code, exitStatus) { root.onRemoveExited() }
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.barText
        onPressed: function(b) { if (root.opened) root.close(); else root.open() }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(320))
        contentHeight: panel.fittedContentHeight(column.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: false
            onMoveRequested: function(dx, dy) {
                if (!root.cursorActive) { root.cursorActive = true; if (dy >= 0) return }
                root.moveCursor(dy)
            }
            onActivateRequested: { root.cursorActive = true; root.activateCursor() }
            onCloseRequested: root.close()
        }

        Column {
            id: column
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)

            Text {
                text: "Face ID"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
            }

            Text {
                text: !root.daemonActive ? "daemon not running"
                    : !root.enrolled ? "no face enrolled"
                    : root.patchApplied ? "active — lock and look"
                    : root.reapplyBlocked ? "update changed the lock screen — re-apply needs review"
                    : "enrolled, lock screen patch is off"
                color: root.bar.foreground
                opacity: root.daemonActive && root.enrolled && root.patchApplied ? 1 : 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.subtitle
            }

            // --- rows ---
            // A Toggle for the on/off state, because that is genuinely a
            // boolean the owner flips, and Buttons for the two actions. The
            // real qs.Ui components are used rather than hand-rolled ones so
            // hover, focus, and theming match the rest of the bar.
            Column {
                width: parent.width
                spacing: Style.space(6)
                visible: root.daemonActive

                Toggle {
                    id: enableToggle
                    width: parent.width
                    label: "Face unlock"
                    description: root.patchApplied
                        ? "On — the lock screen offers face ID"
                        : "Off — the lock screen is stock"
                    checked: root.patchApplied
                    hasCursor: root.focusSection === "enable" && root.cursorActive
                    enabled: !root.busy
                    onClicked: root.setEnabled(!root.patchApplied)
                }

                Row {
                    spacing: Style.space(6)

                    Button {
                        text: root.enrolled ? "Re-enroll" : "Enroll face"
                        hasCursor: root.focusSection === "enroll" && root.cursorActive
                        enabled: !root.busy && root.daemonActive
                        onClicked: root.enroll()
                    }
                    Button {
                        text: "Forget"
                        hasCursor: root.focusSection === "forget" && root.cursorActive
                        enabled: !root.busy && root.enrolled
                        onClicked: root.removeTemplate()
                    }
                }
            }

            // Enrollment progress. Only while a capture is actually running.
            Column {
                width: parent.width
                spacing: Style.space(4)
                visible: root.capturing

                Rectangle {
                    width: parent.width
                    height: 4
                    radius: 2
                    color: root.hoverFill

                    Rectangle {
                        height: parent.height
                        width: parent.width * root.capturePercent / 100
                        radius: 2
                        color: Color.accent
                        Behavior on width { NumberAnimation { duration: 120 } }
                    }
                }
                Text {
                    text: root.captureStatus
                    color: root.bar.foreground
                    opacity: 0.6
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                }
            }

            Text {
                text: root.lastMessage
                visible: root.lastMessage.length > 0 && !root.capturing
                color: root.bar.foreground
                opacity: 0.6
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width
            }
        }
    }
}
