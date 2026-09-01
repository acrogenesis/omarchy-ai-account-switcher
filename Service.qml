import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string codexStorePath: home + "/.config/omarchy/ai-account-switcher/codex-accounts.json"
  readonly property string claudeStorePath: home + "/.config/omarchy/ai-account-switcher/claude-accounts.json"
  readonly property string helperPath: decodeURIComponent(
    String(Qt.resolvedUrl("ai_accounts.sh")).replace(/^file:\/\//, ""))
  readonly property string codexSetupPath: decodeURIComponent(
    String(Qt.resolvedUrl("AddCodexAccount.sh")).replace(/^file:\/\//, ""))
  readonly property string claudeSetupPath: decodeURIComponent(
    String(Qt.resolvedUrl("AddClaudeAccount.sh")).replace(/^file:\/\//, ""))
  readonly property string launchPath: decodeURIComponent(
    String(Qt.resolvedUrl("LaunchAccount.sh")).replace(/^file:\/\//, ""))
  readonly property string wrapperSetupPath: decodeURIComponent(
    String(Qt.resolvedUrl("InstallCommandWrappers.sh")).replace(/^file:\/\//, ""))

  property string provider: "codex"
  readonly property string providerLabel: provider === "claude" ? "Claude" : "Codex"
  property var providerStatuses: ({})
  property var accounts: []
  property string activeAccountId: ""
  property string activeName: "No saved account"
  property string suggestedName: ""
  property bool currentSaved: false
  property bool hasCurrentLogin: false
  property bool canSwitch: true
  property int runningCount: 0
  property bool busy: false
  property bool launching: false
  property bool commandWrappersEnabled: false
  property string switchingId: ""
  property string lastError: ""
  property bool hasActionError: false
  property string lastAction: ""

  function boundedText(value, fallback, maximumLength) {
    var source = value === undefined || value === null || String(value) === ""
      ? String(fallback || "") : String(value)
    var limit = Math.max(1, Number(maximumLength || 256))
    source = source.trim()
    return source.length <= limit ? source : source.slice(0, limit - 1) + "…"
  }

  function displayAccount(value) {
    value = value || {}
    return {
      id: root.boundedText(value.id, "", 128),
      name: root.boundedText(value.name, "Account", 120),
      email: root.boundedText(value.email, "", 254),
      plan_type: root.boundedText(value.plan_type, "", 80),
      subscription_type: root.boundedText(value.subscription_type, "", 80),
      org_name: root.boundedText(value.org_name, "", 120),
      auth_mode: root.boundedText(value.auth_mode, "", 40),
      is_active: value.is_active === true,
      is_current: value.is_current === true,
      last_used_at: root.boundedText(value.last_used_at, "", 80)
    }
  }

  function parseResult(text) {
    try {
      var parsed = JSON.parse(String(text || "{}"))
      return parsed && typeof parsed === "object" ? parsed : {}
    } catch (error) {
      return { ok: false, error: "The account helper returned invalid data" }
    }
  }

  function applyProviderStatus(payload) {
    payload = payload || {}
    var receivedAccounts = Array.isArray(payload.accounts) ? payload.accounts : []
    root.accounts = receivedAccounts.map(function(account) { return root.displayAccount(account) })
    root.activeAccountId = root.boundedText(payload.active_account_id, "", 128)
    root.currentSaved = payload.current_saved === true
    root.hasCurrentLogin = payload.has_current_login === true
    root.suggestedName = root.boundedText(payload.suggested_name, "", 120)
    root.canSwitch = payload.can_switch !== false
    var count = Number(payload.running_count || 0)
    root.runningCount = isFinite(count) ? Math.max(0, Math.floor(count)) : 0
    var active = null
    for (var i = 0; i < root.accounts.length; i++) {
      if (String(root.accounts[i].id || "") === root.activeAccountId) {
        active = root.accounts[i]
        break
      }
    }
    root.activeName = active ? root.boundedText(active.name, "Account", 120)
      : (root.hasCurrentLogin ? "Unsaved login" : "No " + root.providerLabel + " login")
    if (payload.ok === false && !root.hasActionError)
      root.lastError = root.boundedText(payload.error, "Could not load accounts", 320)
  }

  function applyStatus(payload) {
    root.providerStatuses = payload.providers || ({})
    root.commandWrappersEnabled = payload.command_wrappers_enabled === true
    root.applyProviderStatus(root.providerStatuses[root.provider])
  }

  function selectProvider(value) {
    var next = value === "claude" ? "claude" : "codex"
    root.provider = next
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    root.applyProviderStatus(root.providerStatuses[next])
  }

  function refresh() {
    if (!statusProcess.running && !actionProcess.running) statusProcess.running = true
  }

  function runAction(arguments, switchingId) {
    if (root.busy) return
    root.busy = true
    root.switchingId = switchingId || ""
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    actionProcess.command = ["bash", root.helperPath].concat(arguments)
    actionProcess.running = true
  }

  function switchAccount(accountId) {
    if (String(accountId || "") === "") return
    runAction(["switch", root.provider, String(accountId)], String(accountId))
  }

  function importCurrent(name) {
    runAction(["import-current", root.provider, String(name || "")], "")
  }

  function renameAccount(accountId, name) {
    runAction(["rename", root.provider, String(accountId), String(name || "")], "")
  }

  function removeAccount(accountId) {
    runAction(["remove", root.provider, String(accountId)], "")
  }

  function addAnotherAccount() {
    if (setupProcess.running) return
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    setupProcess.command = ["omarchy-launch-terminal", "bash",
      root.provider === "claude" ? root.claudeSetupPath : root.codexSetupPath]
    setupProcess.running = true
  }

  function launchSelectedAccount() {
    if (root.launching || root.activeAccountId === "") return
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    root.launching = true
    launchProcess.command = ["omarchy-launch-terminal", "bash", root.launchPath,
      root.provider, root.activeAccountId]
    launchProcess.running = true
  }

  function enableCommandSwitching() {
    if (root.busy || wrapperProcess.running) return
    root.busy = true
    root.lastError = ""
    root.hasActionError = false
    root.lastAction = ""
    wrapperProcess.command = ["bash", root.wrapperSetupPath, "install"]
    wrapperProcess.running = true
  }

  property Process statusProcess: Process {
    command: ["bash", root.helperPath, "status"]
    stdout: StdioCollector { id: statusOutput; waitForEnd: true }
    stderr: StdioCollector { id: statusError; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseResult(statusOutput.text)
      if (exitCode === 0 && payload.ok === true) {
        root.applyStatus(payload)
        if (!root.hasActionError) root.lastError = ""
      } else {
        if (!root.hasActionError)
          root.lastError = root.boundedText(payload.error || statusError.text,
            "Could not load accounts", 320)
      }
    }
  }

  property Process actionProcess: Process {
    stdout: StdioCollector { id: actionOutput; waitForEnd: true }
    stderr: StdioCollector { id: actionError; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseResult(actionOutput.text)
      root.busy = false
      root.switchingId = ""
      if (exitCode === 0 && payload.ok === true) {
        root.lastAction = root.boundedText(payload.message, "Done", 240)
        root.lastError = ""
        root.hasActionError = false
      } else {
        root.lastError = root.boundedText(payload.error || actionError.text,
          "Account action failed", 320)
        root.hasActionError = true
      }
      root.refresh()
    }
  }

  property Process setupProcess: Process {
    onExited: refreshTimer.restart()
  }

  property Process launchProcess: Process {
    onExited: function(exitCode) {
      root.launching = false
      if (exitCode !== 0) {
        root.lastError = "Could not open the selected " + root.providerLabel + " account"
        root.hasActionError = true
      }
      refreshTimer.restart()
    }
  }

  property Process wrapperProcess: Process {
    stdout: StdioCollector { id: wrapperOutput; waitForEnd: true }
    stderr: StdioCollector { id: wrapperError; waitForEnd: true }
    onExited: function(exitCode) {
      var payload = root.parseResult(wrapperOutput.text)
      root.busy = false
      if (exitCode === 0 && payload.ok === true) {
        root.lastAction = root.boundedText(payload.message, "Terminal commands enabled", 240)
        root.lastError = ""
        root.hasActionError = false
      } else {
        root.lastError = root.boundedText(payload.error || wrapperError.text,
          "Could not enable terminal command switching", 320)
        root.hasActionError = true
      }
      root.refresh()
    }
  }

  FileView {
    path: root.codexStorePath
    watchChanges: true
    printErrors: false
    onLoaded: root.refresh()
    onFileChanged: reload()
    onLoadFailed: root.refresh()
  }

  FileView {
    path: root.claudeStorePath
    watchChanges: true
    printErrors: false
    onLoaded: root.refresh()
    onFileChanged: reload()
    onLoadFailed: root.refresh()
  }

  Timer {
    id: refreshTimer
    interval: 700
    onTriggered: root.refresh()
  }

  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: root.refresh()
}
