#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/Shared/AppRemoteConfiguration.swift"
CONTENT="$ROOT/App/ContentView.swift"
MAP="$ROOT/App/MapHomeView.swift"
SETUP="$ROOT/App/FirstSetupView.swift"
SETTINGS="$ROOT/App/SettingsView.swift"
BUG_REPORT="$ROOT/App/BugReportView.swift"
GITHUB_SUBMISSION="$ROOT/Shared/GitHubSubmission.swift"
DISCUSSION_FORM="$ROOT/.github/DISCUSSION_TEMPLATE/第三方配置分享.yml"
ISSUE_FORM="$ROOT/.github/ISSUE_TEMPLATE/bug-report.yml"
ISSUE_CONFIG="$ROOT/.github/ISSUE_TEMPLATE/config.yml"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

python3 - "$ROOT/version.txt" <<'PY' || exit 1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    config = json.load(handle)

assert config["latestVersion"] == "1.0.8"
assert config["minimumSupportedVersion"] == "1.0.0"
assert "shadowrocket" not in config["communityPromptClients"]
assert set(config["communityPromptClients"]) == {
    "surge", "quantumultX", "loon", "stash", "egern"
}
PY

LATEST_VERSION="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["latestVersion"])' "$ROOT/version.txt")"

grep -Fq "latestVersion: \"$LATEST_VERSION\"" "$CONFIG" \
  || fail "Shared/AppRemoteConfiguration.swift fallback latestVersion must match version.txt ($LATEST_VERSION)"
grep -Fq "version-v$LATEST_VERSION" "$ROOT/README.md" \
  || fail "README.md version badge must match version.txt ($LATEST_VERSION)"
grep -Fq "version-v$LATEST_VERSION" "$ROOT/README.zh-CN.md" \
  || fail "README.zh-CN.md version badge must match version.txt ($LATEST_VERSION)"

grep -q 'static let fallback = AppRemoteConfiguration' "$CONFIG" \
  || fail "the app must ship a built-in remote-configuration fallback"
grep -q 'timeoutIntervalForRequest = 1.5' "$CONFIG" \
  || fail "remote configuration requests must use a short timeout"
grep -q 'timeoutIntervalForResource = 2' "$CONFIG" \
  || fail "remote configuration resource loading must use a short timeout"
grep -q 'gh-proxy.org/https://raw.githubusercontent.com/xweiba/location-spoofer/main/version.txt' "$CONFIG" \
  || fail "update detection must prefer the domestic GitHub Raw mirror"
grep -q 'static let configurationURLs = \[' "$CONFIG" \
  || fail "update detection must retain multiple configuration sources"
! grep -q 'data.count' "$CONFIG" \
  || fail "the client must not impose a remote configuration file-size limit"
grep -q 'docs/releases/v\\(version).md' "$CONFIG" \
  || fail "update notes must come from the archived release document"
grep -q '/releases/latest' "$CONFIG" \
  || fail "missing release notes must fall back to the latest Release page"
grep -q '.task { await checkForUpdates() }' "$CONTENT" \
  || fail "update detection must run asynchronously outside bootstrap"
! grep -A90 'private func bootstrap() async' "$CONTENT" | grep -q 'fetch()' \
  || fail "remote configuration must not block the startup gate"
grep -Fq 'Label("检查更新"' "$SETTINGS" \
  || fail "Settings must expose a manual update check"
grep -Fq 'title: Text("已是最新版本")' "$SETTINGS" \
  || fail "manual update checks must report the current-version result"
grep -Fq 'title: Text("检查更新失败")' "$SETTINGS" \
  || fail "manual update checks must report network failures"

grep -q '社区分享成功配置？' "$MAP" \
  || fail "non-Shadowrocket success must offer community contribution"
grep -q 'Button("去提交")' "$MAP" \
  || fail "community contribution prompt must expose the submit action"
grep -q 'Button("复制模板")' "$MAP" \
  || fail "community contribution prompt must expose an explicit copy action"
grep -q 'Button("取消", role: .cancel)' "$MAP" \
  || fail "the first community prompts must expose cancel"
grep -q 'Button("不再提示", role: .cancel)' "$MAP" \
  || fail "the third community prompt must allow permanent suppression"
grep -q '匿名收录，不在 README 展示投稿账号' "$GITHUB_SUBMISSION" \
  || fail "the contribution template must offer anonymous README attribution"
grep -Fq 'https://github.com/xweiba/location-spoofer/discussions/new?category=%E7%AC%AC%E4%B8%89%E6%96%B9%E9%85%8D%E7%BD%AE%E5%88%86%E4%BA%AB' "$GITHUB_SUBMISSION" \
  || fail "community submission must use one fixed Discussions address"
grep -q 'UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate' "$MAP" \
  || fail "the explicit copy action must copy the contribution template"
grep -A8 'Button("去提交")' "$MAP" | grep -q 'UIPasteboard.general.string = GitHubSubmission.communityContributionTemplate' \
  || fail "the submit action must copy the template before opening GitHub"
grep -A8 'Button("去提交")' "$MAP" | grep -q 'openCommunityContributionPage()' \
  || fail "the submit action must open the fixed Discussions page after copying"
! grep -A12 'private func openCommunityContributionPage' "$MAP" | grep -q 'URLComponents' \
  || fail "the fixed community address must not be rebuilt from dynamic query items"
grep -A4 'private func openCommunityContributionPage' "$MAP" | grep -q 'SafariDestination' \
  || fail "community submission must open with the shared in-App Safari destination"
! grep -A4 'private func openCommunityContributionPage' "$MAP" | grep -q 'UIApplication.shared.open' \
  || fail "community submission must not be intercepted by an external GitHub client"
test -s "$DISCUSSION_FORM" \
  || fail "the fixed Discussions category must provide a maintained submission form"
grep -q 'label: 第三方客户端' "$DISCUSSION_FORM" \
  || fail "the Discussions form must classify submissions by client"
grep -q '匿名收录，不在 README 展示投稿账号' "$DISCUSSION_FORM" \
  || fail "the Discussions form must retain anonymous README attribution"
grep -q '请先移除账号、订阅、密码、设备标识、真实位置等敏感信息' "$DISCUSSION_FORM" \
  || fail "the Discussions form must remind users to remove sensitive information"
grep -q '截图除敏感信息遮挡外不要添加箭头、编号或说明文字' "$DISCUSSION_FORM" \
  || fail "the Discussions form must explain the screenshot annotation rule"
! grep -q 'label: 隐私确认' "$DISCUSSION_FORM" \
  || fail "the Discussions form must not require a separate privacy confirmation"
for field in \
  '## 第三方客户端' \
  '## 第三方客户端版本' \
  '## iOS 版本' \
  '## 配置步骤' \
  '## 截图与补充说明' \
  '## README 收录署名'; do
  grep -Fq "$field" "$GITHUB_SUBMISSION" \
    || fail "the App contribution template must match Discussions field: $field"
done
grep -Fq 'label: 第三方客户端版本' "$DISCUSSION_FORM" \
  || fail "the Discussions form must clearly request the third-party client version"

grep -Fq 'https://github.com/xweiba/location-spoofer/issues/new?template=bug-report.yml' "$GITHUB_SUBMISSION" \
  || fail "the App bug report must open the dedicated Issue form"
grep -Fq 'GitHubSubmission.bugReportURL' "$BUG_REPORT" \
  || fail "the App bug report must use the shared GitHub destination"
grep -Fq 'SafariView(url: destination.url)' "$BUG_REPORT" \
  || fail "the App bug report must open in the shared in-App Safari view"
! grep -q 'UIApplication.shared.open' "$BUG_REPORT" \
  || fail "the App bug report must not be handed to an external GitHub client"
grep -Fq 'App 生成的诊断报告' "$BUG_REPORT" \
  || fail "the App must tell users where to paste the generated report"
grep -Fq 'AppLocalization.string("第三方客户端")' "$BUG_REPORT" \
  || fail "the generated report must identify the selected third-party client"
grep -Fq 'Label("报告 Bug"' "$SETTINGS" \
  || fail "Settings must identify the support action as a bug report"
for action in '使用帮助' '功能建议' '分享第三方配置'; do
  grep -Fq "Label(\"$action\"" "$SETTINGS" \
    || fail "Settings support must expose: $action"
done
grep -A8 'Label("分享第三方配置"' "$SETTINGS" >/dev/null \
  || fail "Settings must retain the manual third-party sharing action"
grep -q 'GitHubSubmission.communityContributionTemplate' "$SETTINGS" \
  || fail "Settings manual sharing must copy the shared contribution template"
grep -q 'SafariView(url: destination.url)' "$SETTINGS" \
  || fail "Settings GitHub support actions must use the in-App Safari view"
test -s "$ISSUE_FORM" \
  || fail "the repository must provide a bug report Issue form"
grep -Fq 'label: App 生成的诊断报告' "$ISSUE_FORM" \
  || fail "the Issue form must expose the field named by the App"
grep -Fq '设置 → 支持 → 报告 Bug' "$ISSUE_FORM" \
  || fail "the Issue form must point users to the matching App workflow"
grep -Fq 'label: 我已移除真实位置、认证信息、订阅地址、证书私钥和其他敏感信息' "$ISSUE_FORM" \
  || fail "the Issue form must require privacy confirmation"
grep -Fq 'blank_issues_enabled: false' "$ISSUE_CONFIG" \
  || fail "blank Issues must be disabled so reports use the maintained form"
for destination in '使用帮助' '功能建议' '第三方配置分享'; do
  grep -Fq "name: $destination" "$ISSUE_CONFIG" \
    || fail "Issue chooser must route non-bug request to $destination"
done

for obsolete in \
  '我已配置，开始检测' \
  '确认完成，重新检测' \
  '下一步：导入配置' \
  '我已导入，检测接口连接'; do
  ! grep -q "$obsolete" "$SETUP" \
    || fail "setup footer must not retain dynamic label: $obsolete"
done
test "$(grep -c 'actionLabel("完成")' "$SETUP")" -eq 4 \
  || fail "all setup footer primary actions must use the fixed 完成 label"

application_line="$(grep -n 'Section("应用")' "$SETTINGS" | head -n 1 | cut -d: -f1)"
certificate_line="$(grep -n 'Section("证书")' "$SETTINGS" | head -n 1 | cut -d: -f1)"
test "$application_line" -lt "$certificate_line" \
  || fail "the APP certificate reset section must appear below the application section"

echo "PASS: update and community contribution contract"
