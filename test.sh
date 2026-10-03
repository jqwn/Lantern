#!/bin/sh
set -eu
cd "$(dirname "$0")"
case "${1:-}" in
    ''|--unit-only) ;;
    *) echo 'Usage: sh test.sh [--unit-only]' >&2; exit 1 ;;
esac
DEVELOPER_DIR_PATH="$(xcode-select -p)"
if [ -d "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks/Testing.framework" ]; then
    swift test --build-system native --disable-xctest \
        -Xswiftc -F -Xswiftc "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks" \
        -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_DIR_PATH/usr/lib/swift/host/plugins/testing" \
        -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
else
    swift test --disable-xctest
fi
if [ "${1:-}" != --unit-only ]; then
    python3 Tests/integration.py
fi
