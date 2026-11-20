import org.kde.breeze.components

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2

import org.kde.plasma.components as PlasmaComponents3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

SessionManagementScreen {
    id: root
    property Item mainPasswordBox: passwordBox

    property bool showUsernamePrompt: !showUserList

    property string lastUserName
    property bool loginScreenUiVisible: false

    //the y position that should be ensured visible when the on screen keyboard is visible
    property int visibleBoundary: mapFromItem(loginButton, 0, 0).y
    onHeightChanged: visibleBoundary = mapFromItem(loginButton, 0, 0).y + loginButton.height + Kirigami.Units.smallSpacing

    property real fontSize: Kirigami.Theme.defaultFont.pointSize

    signal loginRequest(string username, string password)

    onShowUsernamePromptChanged: {
        if (!showUsernamePrompt) {
            lastUserName = ""
        }
    }

    onUserSelected: {
        // Don't startLogin() here, because the signal is connected to the
        // Escape key as well, for which it wouldn't make sense to trigger
        // login.
        passwordBox.clear()
        focusFirstVisibleFormControl();
    }

    QQC2.StackView.onActivating: {
        // Controls are not visible yet.
        Qt.callLater(focusFirstVisibleFormControl);
    }

    function focusFirstVisibleFormControl() {
        const nextControl = (userNameInput.visible
            ? userNameInput
            : (passwordBox.visible
                ? passwordBox
                : loginButton));
        // Using TabFocusReason, so that the loginButton gets the visual highlight.
        nextControl.forceActiveFocus(Qt.TabFocusReason);
    }

    /*
     * Login has been requested with the following username and password
     * If username field is visible, it will be taken from that, otherwise from the "name" property of the currentIndex
     */
    function startLogin() {
        const username = showUsernamePrompt ? userNameInput.text : userList.selectedUser
        const password = passwordBox.text

        footer.enabled = false
        mainStack.enabled = false
        userListComponent.userList.opacity = 0.75

        // This is partly because it looks nicer, but more importantly it
        // works round a Qt bug that can trigger if the app is closed with a
        // TextField focused.
        //
        // See https://bugreports.qt.io/browse/QTBUG-55460
        loginButton.forceActiveFocus();
        loginRequest(username, password);
    }

    // Nothing's design has no avatar grid, but a single circular face above the
    // prompt is the same monochrome language -- one fixed-size silhouette rather
    // than the multicolour user list the theme deliberately avoids.
    //
    // It contributes ZERO height to the login column on purpose. Main.qml sizes
    // mainStack to root.height + 3 gridUnits and leaves it top-aligned, so the
    // bottom of the column sits just off the screen edge; anything that grows
    // the column pushes the power buttons out of view entirely. The avatar is
    // therefore anchored above the username field and overflows upward.
    Item {
        id: faceRow
        Layout.fillWidth: true
        Layout.preferredHeight: 0
        Layout.maximumHeight: 0
        implicitHeight: 0

        // The notification label ("Login Failed", "Caps Lock is on") is laid out
        // ABOVE this row inside SessionManagementScreen's prompts column, and it
        // pushes the whole column down when it appears. The avatar grows upward
        // from here, so the two would occupy the same strip of screen.
        readonly property bool messageShown: notificationMessage
                                             && notificationMessage.length > 0

        // Space budget, measured on the 800px-tall headless greeter: the row
        // sits at y≈510 and the clock ends at y≈228, so the avatar may grow to
        // roughly 8 gridUnits before touching the clock. 4 gridUnits is a
        // comfortable size that stays clear of it on shorter screens too.
        readonly property int faceSize: Kirigami.Units.gridUnit * 4

        // Hidden outright while a message is up: the face is decorative, the
        // message is not. Done with `visible` rather than by shrinking to 0 --
        // a zero-size texture request makes the X server answer
        // "BadValue (integer parameter out of range)".
        visible: showUsernamePrompt && !messageShown

        // The circular crop is baked into the PNG by install/50-login-screen.sh,
        // so this is a plain Image -- no OpacityMask, no effect module.
        Image {
            id: faceImage
            // Bottom edge sits just above the username rule; the image grows up
            // from there into the space between the clock and the prompt.
            anchors.bottom: parent.top
            anchors.bottomMargin: Kirigami.Units.smallSpacing
            anchors.horizontalCenter: parent.horizontalCenter
            visible: faceRow.faceSize > 0
            width: faceRow.faceSize
            height: faceRow.faceSize
            source: "faces/.face.icon"
            fillMode: Image.PreserveAspectFit
            asynchronous: true
            smooth: true
            // Qualify with the id: an unqualified name resolves against the
            // component root, not the parent Item ("faceSize is not defined").
            sourceSize.width: faceRow.faceSize * Screen.devicePixelRatio
            sourceSize.height: faceRow.faceSize * Screen.devicePixelRatio
        }

        // Only when there is no image at all: a thin ring, so the prompt does not
        // look broken.
        Rectangle {
            anchors.fill: faceImage
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: "#444444"
            visible: faceImage.status !== Image.Ready
        }
    }

    PlasmaComponents3.TextField {
        id: userNameInput
        font.family: "NType 82 Mono"
        font.letterSpacing: 2
        color: "#ffffff"
        placeholderTextColor: "#666666"
        horizontalAlignment: TextInput.AlignHCenter
        // Nothing: no box around an input -- one rule, drawn from the centre.
        background: Item {
            Rectangle {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                height: 1
                color: "#333333"
            }
            Rectangle {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                height: 2
                width: parent.parent.activeFocus ? parent.width : 0
                color: "#ffffff"
                Behavior on width {
                    NumberAnimation {
                        duration: 200
                        easing.type: Easing.Bezier
                        easing.bezierCurve: [0.25, 0.1, 0.25, 1.0, 1.0, 1.0]
                    }
                }
            }
        }

        font.pointSize: fontSize + 1
        Layout.fillWidth: true

        text: lastUserName
        visible: showUsernamePrompt
        focus: showUsernamePrompt && !lastUserName //if there's a username prompt it gets focus first, otherwise password does
        placeholderText: i18ndc("plasma-desktop-sddm-theme", "@info:placeholder in textfield", "Username").toUpperCase()

        onAccepted: {
            if (root.loginScreenUiVisible) {
                passwordBox.forceActiveFocus()
            }
        }
    }

    RowLayout {
        Layout.fillWidth: true

        PlasmaExtras.PasswordField {
            id: passwordBox
            font.family: "NType 82 Mono"
            font.letterSpacing: 2
            color: "#ffffff"
            placeholderTextColor: "#666666"
            horizontalAlignment: TextInput.AlignHCenter
            // Nothing: no box around an input -- one rule, drawn from the centre.
            background: Item {
                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                    height: 1
                    color: "#333333"
                }
                Rectangle {
                    anchors.bottom: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 2
                    width: parent.parent.activeFocus ? parent.width : 0
                    color: "#ffffff"
                    Behavior on width {
                        NumberAnimation {
                            duration: 200
                            easing.type: Easing.Bezier
                            easing.bezierCurve: [0.25, 0.1, 0.25, 1.0, 1.0, 1.0]
                        }
                    }
                }
            }

            font.pointSize: fontSize + 1
            Layout.fillWidth: true

            placeholderText: i18ndc("plasma-desktop-sddm-theme",  "@info:placeholder in textfield", "Password").toUpperCase()
            focus: !showUsernamePrompt || lastUserName

            // Disable reveal password action because SDDM does not have the breeze icon set loaded
            rightActions: []

            onAccepted: {
                if (root.loginScreenUiVisible) {
                    startLogin();
                }
            }

            visible: root.showUsernamePrompt || userList.currentItem.needsPassword

            Keys.onEscapePressed: {
                mainStack.currentItem.forceActiveFocus();
            }

            //if empty and left or right is pressed change selection in user switch
            //this cannot be in keys.onLeftPressed as then it doesn't reach the password box
            Keys.onPressed: event => {
                if (event.key === Qt.Key_Left && !text) {
                    userList.decrementCurrentIndex();
                    event.accepted = true
                }
                if (event.key === Qt.Key_Right && !text) {
                    userList.incrementCurrentIndex();
                    event.accepted = true
                }
            }

            Connections {
                target: sddm
                function onLoginFailed() {
                    passwordBox.selectAll()
                    passwordBox.forceActiveFocus()
                }
            }
        }

        PlasmaComponents3.Button {
            id: loginButton
            Accessible.name: i18ndc("plasma-desktop-sddm-theme", "@action:button Accessible name", "Log in")
            Layout.preferredHeight: passwordBox.implicitHeight
            Layout.preferredWidth: text.length === 0 ? loginButton.Layout.preferredHeight : -1

            icon.name: text.length === 0 ? (root.LayoutMirroring.enabled ? "go-previous" : "go-next") : ""

            text: root.showUsernamePrompt || userList.currentItem.needsPassword ? "" : i18nc("@action:button", "Log In")
            onClicked: startLogin()
            Keys.onEnterPressed: clicked()
            Keys.onReturnPressed: clicked()
        }
    }
}
