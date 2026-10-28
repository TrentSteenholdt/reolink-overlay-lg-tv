import QtQuick 2.4
import QtMultimedia 5.0
import Eos.Window 0.1
import Eos.SurfaceGroup 0.1

WebOSWindow {
    id: root
    width: 1920
    height: 1080
    visible: true
    color: "transparent"
    appId: "org.cameraoverlay.lgtv"
    title: "Camera Overlay"
    windowType: "_WEBOS_WINDOW_TYPE_FLOATING"

    property bool videoMode: false
    property int timeoutSeconds: 0
    property int remainingSeconds: 0
    property bool hasFrame: false
    property bool timedOut: false
    property int frameRequest: 0
    property int activeFrame: -1
    property double lastFrameReady: 0
    property string notificationId: ""
    property string notificationMessage: ""
    property string notificationType: ""
    property string notificationSound: "none"
    property int notificationRequest: 0
    property bool notificationInitialized: false
    property bool showNotification: notificationMessage.length > 0 &&
                                   (hasFrame || timedOut || !videoMode)

    function playAlert(sound) {
        personSound.stop()
        carSound.stop()
        doorbellSound.stop()
        if (sound === "motion-person")
            personSound.play()
        else if (sound === "motion-car")
            carSound.play()
        else if (sound === "doorbell")
            doorbellSound.play()
    }

    function refreshNotification() {
        try {
            var request = new XMLHttpRequest()
            notificationRequest += 1
            request.open("GET", "file:///tmp/camera-overlay-notification.json?seq=" + notificationRequest, false)
            request.send()
            if (request.status === 0 || request.status === 200) {
                var payload = JSON.parse(request.responseText)
                if (payload.id && payload.id !== notificationId) {
                    var shouldPlay = notificationInitialized || payload.playOnLoad === true
                    notificationId = payload.id
                    notificationMessage = String(payload.message || "")
                    notificationType = String(payload.type || "")
                    notificationSound = String(payload.sound || "none")
                    var requestedDuration = parseInt(payload.durationSeconds, 10)
                    if (!isNaN(requestedDuration) && requestedDuration >= 1 && requestedDuration <= 86400) {
                        timeoutSeconds = requestedDuration
                        remainingSeconds = requestedDuration
                        expiryTimer.stop()
                        expiryTimer.interval = requestedDuration * 1000
                        expiryTimer.start()
                    }
                    notificationInitialized = true
                    if (shouldPlay)
                        playAlert(notificationSound)
                }
            }
            if (!notificationInitialized)
                notificationInitialized = true
        } catch (error) {
            notificationInitialized = true
        }
    }

    function frameReady(slot) {
        activeFrame = slot
        hasFrame = true
        timedOut = false
        lastFrameReady = Date.now()
    }

    function frameError() {
        if (hasFrame && Date.now() - lastFrameReady > 1200) {
            hasFrame = false
            timedOut = true
        }
    }

    inputRegion: EosRegion { regionRects: [] }

    Component.onCompleted: {
        windowProperties.needFocus = "false"
        try {
            var request = new XMLHttpRequest()
            request.open("GET", "file:///tmp/camera-overlay-mode", false)
            request.send()
            videoMode = (request.status === 0 || request.status === 200) &&
                        request.responseText.trim() === "video"

            var timeoutRequest = new XMLHttpRequest()
            timeoutRequest.open("GET", "file:///tmp/camera-overlay-timeout-seconds", false)
            timeoutRequest.send()
            var configuredTimeout = parseInt(timeoutRequest.responseText.trim(), 10)
            if (!isNaN(configuredTimeout) && configuredTimeout >= 0 && configuredTimeout <= 86400) {
                timeoutSeconds = configuredTimeout
                remainingSeconds = configuredTimeout
            }
        } catch (error) {
            videoMode = false
        }
    }

    Rectangle {
        id: panel
        width: 530
        height: (root.showNotification ? 80 : 4) + 298 + 4
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 55
        anchors.bottomMargin: 55
        color: "#555b63"
        border.color: "white"
        border.width: 2
        radius: 8

        Row {
            id: messageRow
            width: parent.width - 28
            height: 72
            anchors.top: parent.top
            anchors.topMargin: 4
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12
            visible: root.showNotification

            Item {
                width: 42
                height: 36
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    x: 0
                    y: 8
                    width: 42
                    height: 27
                    radius: 4
                    color: "white"
                }

                Rectangle {
                    x: 8
                    y: 3
                    width: 12
                    height: 9
                    radius: 2
                    color: "white"
                }

                Rectangle {
                    x: 13
                    y: 14
                    width: 16
                    height: 16
                    radius: 8
                    color: "#555b63"
                }

                Rectangle {
                    x: 16
                    y: 17
                    width: 10
                    height: 10
                    radius: 5
                    color: "#30343a"
                }

                Rectangle {
                    x: 35
                    y: 12
                    width: 3
                    height: 3
                    radius: 1.5
                    color: "#555b63"
                }
            }

            Text {
                width: parent.width - 54
                height: parent.height
                text: root.notificationMessage
                color: "white"
                font.pixelSize: 22
                font.bold: true
                wrapMode: Text.WordWrap
                verticalAlignment: Text.AlignVCenter
                horizontalAlignment: Text.AlignLeft
            }
        }

        Rectangle {
            id: tile
            width: parent.width - 6
            height: 298
            anchors.top: parent.top
            anchors.topMargin: root.showNotification ? 80 : 4
            anchors.horizontalCenter: parent.horizontalCenter
            color: root.videoMode ? "black" : "#116c91"

            Image {
                id: frameA
                anchors.fill: parent
                cache: false
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                visible: root.videoMode && root.hasFrame && root.activeFrame === 0
                onStatusChanged: {
                    if (status === Image.Ready)
                        root.frameReady(0)
                    else if (status === Image.Error)
                        root.frameError()
                }
            }

            Image {
                id: frameB
                anchors.fill: parent
                cache: false
                asynchronous: true
                fillMode: Image.PreserveAspectFit
                visible: root.videoMode && root.hasFrame && root.activeFrame === 1
                onStatusChanged: {
                    if (status === Image.Ready)
                        root.frameReady(1)
                    else if (status === Image.Error)
                        root.frameError()
                }
            }

            Text {
                anchors.centerIn: parent
                text: root.videoMode ? (root.timedOut ? "Camera unavailable" : "Connecting to camera...") :
                                       "Camera notification"
                color: "white"
                font.pixelSize: 30
                visible: !root.hasFrame
            }
        }

    }

    Text {
        width: panel.width
        height: 28
        anchors.left: panel.left
        anchors.leftMargin: 10
        anchors.top: panel.bottom
        anchors.topMargin: 5
        text: root.timeoutSeconds > 0 ?
              "Press 🔵 to close.   Closing automatically in " + root.remainingSeconds + " secs" :
              "Press 🔵 to close."
        color: "white"
        style: Text.Outline
        styleColor: "black"
        font.pixelSize: 18
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignLeft
    }

    Timer {
        interval: 200
        running: root.videoMode
        repeat: true
        onTriggered: {
            if (frameA.status === Image.Loading || frameB.status === Image.Loading)
                return
            root.frameRequest += 1
            var next = "file:///tmp/camera-overlay-frame.png?seq=" + root.frameRequest
            if (root.activeFrame === 0)
                frameB.source = next
            else
                frameA.source = next
        }
    }

    Timer {
        interval: 300
        running: true
        repeat: true
        onTriggered: root.refreshNotification()
    }

    Timer {
        interval: 4000
        running: root.videoMode
        repeat: false
        onTriggered: root.timedOut = !root.hasFrame
    }

    Timer {
        interval: 1000
        running: root.timeoutSeconds > 0
        repeat: true
        onTriggered: {
            if (root.remainingSeconds > 0)
                root.remainingSeconds -= 1
        }
    }

    Timer {
        id: expiryTimer
        interval: root.timeoutSeconds * 1000
        running: root.timeoutSeconds > 0
        repeat: false
        onTriggered: Qt.quit()
    }

    SoundEffect {
        id: personSound
        source: Qt.resolvedUrl("sounds/motion-person.wav")
        volume: 0.8
    }

    SoundEffect {
        id: carSound
        source: Qt.resolvedUrl("sounds/motion-car.wav")
        volume: 0.8
    }

    SoundEffect {
        id: doorbellSound
        source: Qt.resolvedUrl("sounds/doorbell.wav")
        volume: 0.8
    }

}
