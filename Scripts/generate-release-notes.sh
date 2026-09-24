#!/usr/bin/env bash
set -euo pipefail

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Usage: $0 v<major>.<minor>.<patch>" >&2
  exit 2
fi

if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null; then
  echo "Tag $VERSION already exists; generate the archive before creating the tag." >&2
  exit 1
fi

PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)"
if [[ -n "$PREVIOUS_TAG" ]]; then
  RANGE="$PREVIOUS_TAG..HEAD"
  RANGE_LABEL="$PREVIOUS_TAG..$VERSION"
else
  RANGE="HEAD"
  RANGE_LABEL="initial..$VERSION"
fi

COMMITS="$(git log "$RANGE" --no-merges --format='- `%h` %s')"
if [[ -z "$COMMITS" ]]; then
  echo "No commits found in $RANGE; refusing to create empty release notes." >&2
  exit 1
fi

OUTPUT="docs/releases/${VERSION}.md"
mkdir -p "$(dirname "$OUTPUT")"
cat > "$OUTPUT" <<EOF
# ${VERSION}

发布日期：$(date +%F)

## 提交变更总结

${COMMITS}

## 自签安装

- Release 附件为未签名 IPA，安装前需要自行签名。
- 可使用免费 Apple ID 和 Impactor 完成签名安装，无需付费开发者账号。
- 签名时请保留 Bundle ID \`com.paopaolabs.location-spoofer\`、App Group \`group.com.paopaolabs.location-spoofer\` 及原有 entitlements。
- 免费 Apple ID 签名通常只有 7 天有效期，到期后需要重新签名安装。

<!-- commit-range: ${RANGE_LABEL} -->
EOF

echo "Generated $OUTPUT from $RANGE"
echo "Before tagging, add docs/releases/${VERSION}.en.md and docs/releases/${VERSION}.zh-Hant.md."
