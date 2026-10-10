#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc -parse-as-library \
  ScreenRecall/Core/CaptureModels.swift \
  ScreenRecall/Capture/CaptureScheduler.swift \
  ScreenRecall/Capture/CaptureCoordinator.swift \
  Validation/EngineTests.swift \
  -o .build/engine-tests \
  -Xfrontend -strict-concurrency=complete
.build/engine-tests
