import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Ui

Item {
  id: root

  property string backgroundPath: ""
  property int backgroundVersion: 0
  property bool fingerprintConfigured: false
  // irface face unlock (local patch)
  property bool faceConfigured: false
  property bool faceAuthenticating: false
  // "idle" | "scanning" | "recognized"
  property string faceState: "idle"
  property string faceStatus: ""
  // False once the poller has given up on an empty room. The click target
  // below is only offered while this is false, so the camera never runs
  // without an explicit request.
  property bool faceArmed: true
  signal armFaceRequested()
  property bool authenticatingPassword: false
  property string failureMessage: ""
  property int failedAttempts: 0
  property bool inputEnabled: true
  property bool loadBackground: true
  property string passwordText: ""
  property bool syncingPasswordText: false

  readonly property string placeholderText: "Enter Password"
  readonly property int fieldWidth: 381
  readonly property int fieldHeight: 67
  readonly property int outlineThickness: 3
  readonly property int fieldFontSize: Math.round(Style.font.heading * 1.125)
  readonly property int passwordDotFontSize: Math.round(Style.font.heading * 1.33)
  readonly property int passwordDotLetterSpacing: Math.round(Style.font.heading * 0.19)
  // Space to keep clear on each side of the field for the fingerprint icon
  // (icon width plus a gap) so the centered dots never run under it.
  readonly property real fingerprintReserve: fingerprintConfigured ? Math.round(fingerprintIcon.implicitWidth + 12) : 0
  // Shrink the dots to fit once the password outgrows the field, so every
  // keystroke stays visible — otherwise long passwords clip with no feedback.
  readonly property real passwordDotScale: dotMetrics.advanceWidth > 0
    ? Math.min(1, (passwordInput.width - 4) / dotMetrics.advanceWidth)
    : 1
  readonly property bool showPasswordCursor: inputEnabled && !authenticatingPassword && failureMessage.length === 0
  readonly property bool errorState: failureMessage.length > 0
  readonly property var inputBorderSpec: errorState
    ? Border.surfaceSpec("lock", "border-error", Color.lock.borderError, root.outlineThickness, "border-alpha")
    : Border.surfaceSpec("lock", "border-active", Color.lock.borderActive, root.outlineThickness, "border-alpha")

  signal submitPassword(string password)
  signal passwordTextEdited(string password)
  signal clearFailureRequested()
  signal wakeRequested()

  // Cache-busts the lock background by appending `?v=`. Adding a query
  // string keeps Image's loader happy while forcing it to reload when the
  // user picks a new background mid-session.
  function fileUrl(path) {
    if (!path) return ""
    var encoded = String(path).split("/").map(encodeURIComponent).join("/")
    return "file://" + encoded + "?v=" + backgroundVersion
  }

  function forcePasswordFocus() {
    passwordInput.forceActiveFocus()
  }

  function clearPassword() {
    passwordTextEdited("")
  }

  function syncPasswordText() {
    if (passwordInput.text === passwordText) return
    syncingPasswordText = true
    passwordInput.text = passwordText
    syncingPasswordText = false
  }

  onPasswordTextChanged: syncPasswordText()
  onInputEnabledChanged: {
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }
  Component.onCompleted: {
    syncPasswordText()
    if (inputEnabled) Qt.callLater(forcePasswordFocus)
  }

  // Measures the masked password at full size; passwordDotScale compares this
  // against the field width to decide how far the dots must shrink to fit.
  TextMetrics {
    id: dotMetrics
    font.family: Style.font.family
    font.pixelSize: root.passwordDotFontSize
    font.letterSpacing: root.passwordDotLetterSpacing
    text: "●".repeat(passwordInput.text.length)
  }

  Rectangle {
    anchors.fill: parent
    color: Color.background

    Image {
      id: wallpaper
      anchors.fill: parent
      source: root.loadBackground ? root.fileUrl(root.backgroundPath) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      cache: false
      sourceSize.width: width
      sourceSize.height: height
    }

    MultiEffect {
      anchors.fill: wallpaper
      source: wallpaper
      autoPaddingEnabled: false
      blurEnabled: root.loadBackground && wallpaper.status === Image.Ready
      blur: 1.0
      blurMax: 128
      blurMultiplier: 1.25
      contrast: -0.08
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      onClicked: { root.wakeRequested(); root.forcePasswordFocus() }
      onPositionChanged: root.wakeRequested()
    }

    // --- irface Face ID scanner (local patch) ---
    // Sits just above the password field, in the iOS position. Corner brackets
    // frame the face and a highlight sweeps down while a probe runs; the whole
    // panel turns into a checkmark on a match. Hidden entirely when the daemon
    // is not available, so the stock lock looks untouched.
    Item {
      id: faceScanner
      // Also visible while disarmed so the "Use face unlock" button has a home;
      // the glyph inside is dimmed to show nothing is being scanned.
      visible: root.faceConfigured || !root.faceArmed
      width: 96
      height: 96
      anchors.horizontalCenter: inputField.horizontalCenter
      anchors.bottom: inputField.top
      anchors.bottomMargin: 40

      readonly property color accent: root.faceState === "recognized"
        ? "#3ddc84"
        : Color.lock.borderActive

      // Bracket thickness and inset give the rounded-corner frame.
      Rectangle {
        anchors.fill: parent
        radius: width * 0.28
        color: "transparent"
        border.width: 3
        border.color: faceScanner.accent
        opacity: root.faceState === "idle" ? 0.45 : 0.9
        Behavior on opacity { NumberAnimation { duration: 220 } }
      }

      // The sweeping scan line. Only travels while a probe is actually in
      // flight, so an idle lock screen stays still.
      Rectangle {
        id: scanLine
        width: parent.width * 0.56
        height: 3
        radius: 1.5
        color: faceScanner.accent
        opacity: root.faceAuthenticating ? 0.95 : 0
        x: (parent.width - width) / 2
        y: root.faceAuthenticating
          ? (parent.height - height) * scanProgress
          : (parent.height - height) / 2

        property real scanProgress: 0

        SequentialAnimation on scanProgress {
          running: root.faceAuthenticating
          loops: Animation.Infinite
          NumberAnimation { from: 0; to: 1; duration: 900; easing.type: Easing.InOutQuad }
          NumberAnimation { from: 1; to: 0; duration: 900; easing.type: Easing.InOutQuad }
        }
        Behavior on opacity { NumberAnimation { duration: 180 } }
      }

      // Center glyph: face while scanning, checkmark once recognized.
      Text {
        anchors.centerIn: parent
        font.family: Style.font.family
        font.pixelSize: Math.round(faceScanner.width * 0.4)
        color: faceScanner.accent
        text: root.faceState === "recognized" ? "✓" : "󰓛"
        // Dimmed while disarmed: nothing is being scanned, and the button below
        // is the way to start.
        opacity: root.faceArmed ? (root.faceState === "idle" ? 0.5 : 1) : 0.25

        Behavior on color { ColorAnimation { duration: 180 } }
        Behavior on opacity { NumberAnimation { duration: 180 } }

        // A short pop on match, then settle. The id sits on the animation
        // itself: calling restart() on the child NumberAnimation instead only
        // warns ("non-root animation node") and does not actually run.
        SequentialAnimation on scale {
          id: pop
          running: false
          NumberAnimation { from: 1; to: 1.18; duration: 140; easing.type: Easing.OutQuad }
          NumberAnimation { from: 1.18; to: 1; duration: 180; easing.type: Easing.InOutQuad }
        }
        onTextChanged: function() { if (text === "\u2713") pop.restart() }
      }

      // Status line under the scanner, e.g. the liveness prompt.
      Text {
        visible: root.faceStatus.length > 0
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.bottom
        anchors.topMargin: 10
        text: root.faceStatus
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(Style.font.heading * 0.62)
      }

      // Re-arm affordance. Shown only once the poller has disarmed itself
      // because the room stayed empty, which is also the state that lets the
      // display blank and the machine suspend. Clicking this is what starts
      // the camera again.
      Rectangle {
        id: faceArmButton
        // Gated on being disarmed, not on faceConfigured: the config probe is
        // asynchronous, so for a moment after a lock both are false and the
        // button would be invisible exactly when the owner needs it.
        visible: !root.faceArmed && !root.authenticatingPassword
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.bottom
        anchors.topMargin: 12
        width: armLabel.implicitWidth + 44
        height: 34
        radius: height / 2
        color: "transparent"
        border.width: 1
        border.color: faceScanner.accent
        opacity: 0.85

        Text {
          id: armLabel
          anchors.centerIn: parent
          text: "Use face unlock"
          color: faceScanner.accent
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.heading * 0.62)
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onEntered: faceArmButton.opacity = 1
          onExited: faceArmButton.opacity = 0.85
          onClicked: root.armFaceRequested()
        }
      }
    }

    BorderSurface {
      id: inputField
      width: root.fieldWidth
      height: root.fieldHeight
      anchors.centerIn: parent
      color: Color.lock.background
      borderSpec: root.inputBorderSpec
      radius: Style.cornerRadius
      clip: true

      TextInput {
        id: passwordInput
        anchors.fill: parent
        anchors.topMargin: inputField.borderTop
        // Reserve the fingerprint icon's width on both sides so the centered
        // dots stay symmetric and never slide under the icon as they grow.
        anchors.rightMargin: inputField.borderRight + 18 + root.fingerprintReserve
        anchors.bottomMargin: inputField.borderBottom
        anchors.leftMargin: inputField.borderLeft + 18 + root.fingerprintReserve
        verticalAlignment: TextInput.AlignVCenter
        horizontalAlignment: TextInput.AlignHCenter
        activeFocusOnPress: true
        clip: true
        enabled: root.inputEnabled && !root.authenticatingPassword
        readOnly: root.authenticatingPassword
        echoMode: TextInput.Password
        passwordCharacter: "\u25CF"
        passwordMaskDelay: 0
        color: Color.lock.text
        selectionColor: Color.lock.selection
        selectedTextColor: Color.lock.text
        font.family: Style.font.family
        font.pixelSize: text.length > 0 ? Math.max(1, Math.floor(root.passwordDotFontSize * root.passwordDotScale)) : root.fieldFontSize
        font.letterSpacing: text.length > 0 ? root.passwordDotLetterSpacing * root.passwordDotScale : 0
        cursorVisible: activeFocus && root.showPasswordCursor && text.length > 0
        cursorDelegate: Rectangle {
          width: 2
          color: Color.lock.text
          visible: passwordInput.cursorVisible
        }

        onTextChanged: {
          if (!root.syncingPasswordText) root.passwordTextEdited(text)
          if (text.length > 0) {
            root.wakeRequested()
          }
          if (text.length > 0 && root.failureMessage.length > 0) root.clearFailureRequested()
        }

        onAccepted: {
          var submitted = root.passwordText
          root.passwordTextEdited("")
          if (submitted.length > 0) root.submitPassword(submitted)
        }

        Keys.onPressed: function(event) {
          root.wakeRequested()
          if (event.key === Qt.Key_Escape || (event.modifiers & Qt.ControlModifier && event.key === Qt.Key_U)) {
            root.passwordTextEdited("")
            event.accepted = true
          }
        }
      }

      Text {
        textFormat: Text.PlainText
        anchors.fill: passwordInput
        text: root.authenticatingPassword ? "Checking…" : (root.failureMessage.length > 0 ? root.failureMessage : root.placeholderText)
        visible: passwordInput.text.length === 0
        color: root.authenticatingPassword ? Color.lock.text : (root.failureMessage.length > 0 ? Color.lock.textError : Color.lock.placeholder)
        font.family: Style.font.family
        font.pixelSize: root.fieldFontSize
        font.italic: !root.authenticatingPassword && root.failureMessage.length > 0
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
      }

      // Fingerprint hint pinned inside the field's right edge when a sensor is
      // enrolled, so the user knows they can touch to unlock instead of typing.
      // Matches hyprlock, which draws its fingerprint icon in the same spot.
      Text {
        id: fingerprintIcon
        objectName: "fingerprintIndicator"
        anchors.right: parent.right
        anchors.rightMargin: inputField.borderRight + 18
        anchors.verticalCenter: parent.verticalCenter
        visible: root.fingerprintConfigured
        text: "󰈷"
        color: Color.lock.placeholder
        font.family: Style.font.family
        font.pixelSize: Math.round(root.fieldFontSize * 1.1)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
      }
    }
  }
}
