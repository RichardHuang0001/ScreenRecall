#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build
swiftc -parse-as-library \
  ScreenRecall/Core/CaptureModels.swift \
  ScreenRecall/Capture/ImageEncoder.swift \
  ScreenRecall/Storage/SQLiteDatabase.swift \
  ScreenRecall/Storage/AssetFileStore.swift \
  ScreenRecall/Storage/StorageWriterLock.swift \
  ScreenRecall/Storage/HistoryRepository.swift \
  ScreenRecall/Storage/RetentionManager.swift \
  ScreenRecall/Storage/PersistentCaptureSink.swift \
  Validation/StorageTests.swift \
  -o .build/storage-tests \
  -Xfrontend -strict-concurrency=complete \
  -lsqlite3
.build/storage-tests
