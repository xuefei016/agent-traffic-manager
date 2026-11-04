#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
if [[ "${1:-}" != '--no-build' ]]; then /bin/zsh "$PROJECT_DIR/build.sh" --universal; fi
APP="$PROJECT_DIR/dist/Agent 流量管家.app"
codesign --verify --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 '应用版本号无效。'; exit 1; }
PACKAGE_NAME="AgentBattery-${VERSION}-macOS"
PACKAGE_DIR="$PROJECT_DIR/build/package/$PACKAGE_NAME"
mkdir -p "$PROJECT_DIR/build/package" "$PROJECT_DIR/dist"
if [[ -d "$PACKAGE_DIR" ]]; then rm -rf "$PACKAGE_DIR"; fi
mkdir -p "$PACKAGE_DIR/dist" "$PACKAGE_DIR/scripts"
ditto "$APP" "$PACKAGE_DIR/dist/Agent 流量管家.app"
cp "$PROJECT_DIR/一键安装.command" "$PROJECT_DIR/install.sh" "$PROJECT_DIR/LICENSE" "$PACKAGE_DIR/"
cp "$PROJECT_DIR/scripts/install.sh" "$PACKAGE_DIR/scripts/install.sh"
cp "$PROJECT_DIR/README.md" "$PROJECT_DIR/PRIVACY.md" "$PACKAGE_DIR/"
ditto "$PROJECT_DIR/docs" "$PACKAGE_DIR/docs"
ZIP="$PROJECT_DIR/dist/$PACKAGE_NAME.zip"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$PACKAGE_DIR" "$ZIP"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "${ZIP:t}" > SHA256SUMS.txt)
print "已打包：$ZIP"
