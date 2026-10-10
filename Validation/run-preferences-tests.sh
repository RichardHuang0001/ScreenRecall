#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc -parse-as-library ScreenRecall/App/AppPreferences.swift Validation/PreferencesTests.swift -o .build/preferences-tests -Xfrontend -strict-concurrency=complete
.build/preferences-tests
