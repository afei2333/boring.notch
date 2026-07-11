#!/bin/bash
#
# build_and_resign.sh
#
# 构建 Release 版 LLD-AI.app，拷贝到项目根目录，并做「递归深度重签名」：
# 用本地 ad-hoc 签名把框架、XPC helper 和主程序统一重签为一致的签名，
# 同时保留每个二进制各自的 entitlements（主程序是沙盒应用、helper 不同，
# 不能用一份 entitlements 覆盖全部，所以用 --preserve-metadata=entitlements）。
#
# 用法:
#   ./build_and_resign.sh            # 构建 + 拷贝到根目录 + 深度重签名 + 校验
#   ./build_and_resign.sh --clean    # 先删除旧的构建产物再构建
#   SKIP_BUILD=1 ./build_and_resign.sh   # 跳过构建，只对已编译产物重签名
#   SIGN_IDENTITY="Apple Development: xxx" ./build_and_resign.sh  # 用真实证书代替 ad-hoc
#
set -euo pipefail

# ---------- 配置 ----------
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$PROJECT_ROOT/boringNotch.xcodeproj"
SCHEME="boringNotch"
CONFIG="Release"
DERIVED="$PROJECT_ROOT/.build_release"
APP_NAME="LLD-AI.app"
BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME"
DEST_APP="$PROJECT_ROOT/$APP_NAME"

# 签名身份：默认本地 ad-hoc（"-"）。可用 SIGN_IDENTITY 覆盖成真实证书。
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# 指向完整版 Xcode（命令行工具版没有 xcodebuild）
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# ---------- 0. 可选：清理旧产物 ----------
if [[ "${1:-}" == "--clean" ]]; then
  echo "==> 清理旧构建产物…"
  rm -rf "$DERIVED" "$PROJECT_ROOT/Build" "$PROJECT_ROOT/build_local" "$PROJECT_ROOT/build" "$DEST_APP"
fi

# ---------- 1. 构建 Release ----------
if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> 构建 $SCHEME ($CONFIG)…"
  xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    -destination 'platform=macOS' \
    | tail -5
fi

if [[ ! -d "$BUILT_APP" ]]; then
  echo "❌ 找不到构建产物: $BUILT_APP" >&2
  exit 1
fi

# ---------- 2. 拷贝到项目根目录 ----------
echo "==> 拷贝到项目根目录: $DEST_APP"
rm -rf "$DEST_APP"
cp -R "$BUILT_APP" "$DEST_APP"

# ---------- 3. 递归深度重签名 ----------
# 清除扩展属性，避免 codesign 报 "resource fork / detritus" 或 quarantine
echo "==> 清除扩展属性…"
xattr -cr "$DEST_APP"

echo "==> 递归深度重签名（identity = $SIGN_IDENTITY）…"
# --deep   : 自动从内到外递归签名（框架 / XPC / 主程序）
# --force  : 覆盖已有签名
#
# 注意：这里【故意不】用 --preserve-metadata=flags,runtime。
# Xcode 的 Release 默认开启 Hardened Runtime（codesign flag 0x10000）。
# 如果保留它，但只用本地 ad-hoc 签名又没公证(notarize)，macOS 会触发
# 库验证(Library Validation) + Gatekeeper 全量扫描，导致 app 打不开或
# 启动极慢。纯 ad-hoc 重签会把 runtime/entitlements 一起清掉，得到一个
# 普通的非沙盒 ad-hoc app（flags=0x2），本地秒开可用。
codesign --force --deep --sign "$SIGN_IDENTITY" "$DEST_APP"

# ---------- 4. 校验 ----------
echo "==> 校验签名…"
codesign --verify --deep --strict --verbose=2 "$DEST_APP"
codesign -dv --verbose=2 "$DEST_APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier"

echo "✅ 完成: $DEST_APP"
