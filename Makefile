APP_BUNDLE = build/bin/UX-Music.app
RESOURCES_BIN = $(APP_BUNDLE)/Contents/Resources/bin
SWIFT_SIDECAR_BIN = swift/lyrics-sync/.build/release/lyrics-sync-swift

.PHONY: build dev clean lyrics-sync-python

build:
	swift build -c release --package-path swift/lyrics-sync
	wails build
	mkdir -p $(RESOURCES_BIN)
	cp bin/macos/cdparanoia $(RESOURCES_BIN)/cdparanoia
	cp $(SWIFT_SIDECAR_BIN) $(RESOURCES_BIN)/lyrics-sync-swift
	chmod +x $(RESOURCES_BIN)/cdparanoia
	chmod +x $(RESOURCES_BIN)/lyrics-sync-swift

dev:
	wails dev

# Create python/.venv and install Demucs / faster-whisper / alignment deps (requires uv or python3).
lyrics-sync-python:
	@chmod +x scripts/setup-lyrics-sync-python.sh 2>/dev/null || true
	@./scripts/setup-lyrics-sync-python.sh

clean:
	rm -rf build/bin
