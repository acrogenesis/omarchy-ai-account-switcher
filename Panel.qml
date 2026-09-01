import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "acrogenesis.ai-account-switcher"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.45)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  property int cursorIndex: 0
  property bool cursorActive: false

  function open() {
    if (service) service.refresh()
    cursorIndex = 0
    cursorActive = false
    controller.show()
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function moveCursor(direction) {
    if (!service || service.accounts.length === 0) return
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(service.accounts.length - 1, cursorIndex + direction))
  }

  function activateCursor() {
    if (!service || !cursorActive || cursorIndex >= service.accounts.length) return
    service.switchAccount(service.accounts[cursorIndex].id)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: nameField.activeFocus
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if ((text === "r" || text === "R") && root.service) root.service.refresh()
        else if ((text === "a" || text === "A") && root.service) root.service.addAnotherAccount()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.service
              ? root.service.providerLabel + " · " + root.service.activeName
              : "AI accounts"
            meta: !root.service ? "Service unavailable"
              : (root.service.runningCount > 0
                ? root.service.runningCount + " active " + root.service.providerLabel + " session"
                  + (root.service.runningCount === 1 ? "" : "s")
                : root.service.accounts.length + " saved account"
                  + (root.service.accounts.length === 1 ? "" : "s"))
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: "󱚣"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          ButtonGroup {
            width: parent.width
            value: root.service ? root.service.provider : "codex"
            options: [
              { value: "codex", label: "Codex" },
              { value: "claude", label: "Claude" }
            ]
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: false
            onChanged: function(value) {
              root.cursorIndex = 0
              root.cursorActive = false
              if (root.service) root.service.selectProvider(value)
            }
          }

          BorderSurface {
            visible: root.service && root.service.lastError !== ""
            width: parent.width
            implicitHeight: errorText.implicitHeight + Style.space(20)
            color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
            borderSpec: Border.flat(Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: errorText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              text: root.service ? root.service.lastError : ""
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              maximumLineCount: 4
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: root.service && root.service.lastError === "" && root.service.lastAction !== ""
            width: parent.width
            text: root.service ? root.service.lastAction : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            maximumLineCount: 2
            elide: Text.ElideRight
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "ACCOUNTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            textFormat: Text.PlainText
            visible: root.service && root.service.accounts.length === 0
            width: parent.width
            text: !root.service ? ""
              : (root.service.hasCurrentLogin
                ? "Save the current " + root.service.providerLabel + " login below to start."
                : "Log in to " + root.service.providerLabel + ", then save that login here.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            topPadding: Style.space(8)
            bottomPadding: Style.space(8)
          }

          Column {
            id: accountList
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.service ? root.service.accounts : []

              AccountRow {
                required property var modelData
                required property int index
                width: accountList.width
                account: modelData
                rowIndex: index
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          PanelSectionHeader {
            width: parent.width
            text: "SAVE CURRENT " + (root.service ? root.service.providerLabel.toUpperCase() : "AI") + " LOGIN"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            TextField {
              id: nameField
              width: parent.width - saveButton.width - parent.spacing
              placeholderText: root.service && root.service.suggestedName
                ? root.service.suggestedName : "Account name (optional)"
              maximumLength: 120
              foreground: root.foreground
              font.family: root.fontFamily
              enabled: root.service && root.service.hasCurrentLogin && !root.service.busy
              onAccepted: saveButton.clicked()
            }

            Button {
              id: saveButton
              text: root.service && root.service.currentSaved ? "Update" : "Save"
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: true
              enabled: root.service && root.service.hasCurrentLogin && !root.service.busy
              onClicked: {
                if (!root.service) return
                root.service.importCurrent(nameField.text)
                nameField.text = ""
                keyCatcher.forceActiveFocus()
              }
            }
          }

          Button {
            width: parent.width
            text: root.service && root.service.activeAccountId !== ""
              ? "Open " + root.service.providerLabel + " as " + root.service.activeName
              : "Select a saved account to open " + (root.service ? root.service.providerLabel : "AI")
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            enabled: root.service && root.service.activeAccountId !== ""
              && !root.service.busy && !root.service.launching
            onClicked: {
              root.close()
              root.service.launchSelectedAccount()
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Each launched session keeps this account, even after you select another one."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Button {
            visible: root.service && !root.service.commandWrappersEnabled
            width: parent.width
            text: "Make plain codex and claude commands follow selection"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            enabled: root.service && !root.service.busy
            onClicked: root.service.enableCommandSwitching()
          }

          Text {
            textFormat: Text.PlainText
            visible: root.service && root.service.commandWrappersEnabled
            width: parent.width
            text: "New plain codex and claude processes also use the selected accounts."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Button {
            width: parent.width
            text: "Add another " + (root.service ? root.service.providerLabel : "AI") + " account"
            foreground: root.foreground
            fontFamily: root.fontFamily
            focusable: true
            enabled: root.service && !root.service.busy
            onClicked: {
              root.close()
              root.service.addAnotherAccount()
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Runs an isolated official " + (root.service ? root.service.providerLabel : "AI")
              + " login without disturbing active sessions."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: "Sessions opened from this panel use the selected login. Middle-click the bar icon to refresh."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }

  component AccountRow: CursorSurface {
    id: accountRow
    property var account: null
    property int rowIndex: 0
    readonly property bool currentAccount: account && account.is_active === true
    readonly property bool switching: account && root.service
      && root.service.switchingId === String(account.id || "")

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    current: currentAccount
    foreground: root.foreground
    accent: root.accent
    implicitHeight: row.implicitHeight + Style.space(16)

    RowLayout {
      id: row
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: accountRow.switching ? "󰑓" : (accountRow.currentAccount ? "󰄬" : "󰀄")
        color: accountRow.currentAccount ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.preferredWidth: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: accountRow.account ? String(accountRow.account.name || "Account") : "Account"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: accountRow.currentAccount
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: {
            if (!accountRow.account) return ""
            var pieces = []
            if (accountRow.account.email) pieces.push(accountRow.account.email)
            if (accountRow.account.plan_type) pieces.push(String(accountRow.account.plan_type).toUpperCase())
            if (accountRow.account.subscription_type)
              pieces.push(String(accountRow.account.subscription_type).toUpperCase())
            if (accountRow.account.org_name) pieces.push(String(accountRow.account.org_name))
            if (accountRow.account.distrobox) pieces.push("IN " + String(accountRow.account.distrobox).toUpperCase())
            if (accountRow.currentAccount) pieces.push("SELECTED")
            return pieces.join(" · ")
          }
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: root.service && !root.service.busy ? Qt.PointingHandCursor : Qt.ArrowCursor
      enabled: root.service && !root.service.busy
      onEntered: {
        root.cursorActive = true
        root.cursorIndex = accountRow.rowIndex
      }
      onClicked: if (accountRow.account) root.service.switchAccount(accountRow.account.id)
    }
  }
}
