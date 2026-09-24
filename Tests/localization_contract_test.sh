#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STRINGS="$ROOT/Resources/en.lproj/Localizable.strings"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

plutil -lint "$STRINGS" >/dev/null || fail "English localization file is invalid"

ruby - "$STRINGS" <<'RUBY' || exit 1
path = ARGV.fetch(0)
entries = File.readlines(path).map do |line|
  match = line.match(/^"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)";/)
  [match[1], match[2]] if match
end.compact

duplicates = entries.group_by(&:first).select { |_key, values| values.length > 1 }.keys
abort "FAIL: duplicate English localization keys: #{duplicates.join(', ')}" unless duplicates.empty?

placeholder = /%(?:\d+\$)?(?:@|lld|ld|d|f)/
entries.each do |source, target|
  source_count = source.scan(placeholder).length
  target_count = target.scan(placeholder).length
  abort "FAIL: placeholder mismatch for #{source.inspect}" unless source_count == target_count
end
RUBY

for key in \
  '环境信息' \
  '复制 %@' \
  '已复制 %@' \
  '诊断日志' \
  '======== 代理验证测试 ========' \
  '======== 第三方代理连接检测 ========' \
  '======== 第三方代理运行检测 ========' \
  '第三方代理测试模式：模块连接成功；已保存坐标=%@' \
  '成功：{\"success\":true,\"longitude\":113.0,\"latitude\":22.0,\"accuracy\":25}\n失败：{\"success\":false,\"error\":\"错误说明\"}'; do
  grep -Fq "\"$key\" = " "$STRINGS" || fail "missing critical English localization: $key"
done

grep -q 'localizedCategory' "$ROOT/Shared/RuntimeLog.swift" \
  || fail "runtime log categories must be localized when rendered"
grep -q 'localizedDetailsText' "$ROOT/App/DiagnosticsView.swift" \
  || fail "runtime log details must be localized in the diagnostics UI"
grep -q 'AppLocalization.string("诊断日志")' "$ROOT/App/BugReportView.swift" \
  || fail "generated bug reports must localize their diagnostic section"
grep -q 'log("  " + e.localizedMessage)' "$ROOT/App/SetupCoordinator.swift" \
  || fail "bug-report verification logs must render stored messages in the active language"

if grep -R -n 'raw.githubusercontent.com/Yu9191/wloc' \
  "$ROOT/App" "$ROOT/Shared" "$ROOT/Resources/ThirdPartyProxyModules" \
  "$ROOT/ThirdParty/WlocScripts/modules"; then
  fail "deleted Yu9191/wloc repository must not remain a runtime dependency"
fi

# Check the real Foundation lookup path, not just the existence of locale files.
grep -q 'developmentLanguage: en' "$ROOT/project.yml" \
  || fail "English must be the development-language fallback"
grep -q '  - zh-Hant' "$ROOT/project.yml" \
  || fail "Traditional Chinese must be a supported region"
for locale in zh-Hans zh-Hant; do
  plutil -lint "$ROOT/Resources/$locale.lproj/Localizable.strings" >/dev/null \
    || fail "$locale localization file is invalid"
  plutil -lint "$ROOT/Resources/$locale.lproj/InfoPlist.strings" >/dev/null \
    || fail "$locale permission prompts are invalid"
done

ruby - "$STRINGS" "$ROOT/Resources/zh-Hans.lproj/Localizable.strings" \
  "$ROOT/Resources/zh-Hant.lproj/Localizable.strings" <<'RUBY' || exit 1
paths = ARGV
keys = paths.map { |path| File.readlines(path).map { |line| line[/^"((?:\\.|[^"\\])*)"\s*=/, 1] }.compact }
abort "FAIL: Chinese tables must cover every English key" unless keys[1] == keys[0] && keys[2] == keys[0]
RUBY

grep -Fq '"虚拟定位" = "虚拟定位";' "$ROOT/Resources/zh-Hans.lproj/Localizable.strings" \
  || fail "Simplified Chinese must resolve the source key"
grep -Fq '"虚拟定位" = "虛擬定位";' "$ROOT/Resources/zh-Hant.lproj/Localizable.strings" \
  || fail "Traditional Chinese must use Traditional characters"

swift - <<'SWIFT' || fail "language selection differs from expected behavior"
import Foundation
let available = ["en", "zh-Hans", "zh-Hant"]
for (language, expected) in [
    ("zh-CN", "zh-Hans"), ("zh-TW", "zh-Hant"), ("zh-HK", "zh-Hant"),
    ("it-IT", "en"), ("fr-FR", "en")
] {
    let selected = Bundle.preferredLocalizations(from: available, forPreferences: [language]).first
    guard selected == expected else {
        fputs("FAIL: \(language) selected \(selected ?? "nil")\n", stderr)
        exit(1)
    }
}
SWIFT

echo "PASS: localization and diagnostic export contract"
