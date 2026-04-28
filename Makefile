APP_BUNDLE = build/bin/UX-Music.app
RESOURCES_BIN = $(APP_BUNDLE)/Contents/Resources/bin

.PHONY: build dev clean lyrics-sync-python test-lyrics-sync test-lyrics-sync-ignore-e2e

build:
	wails build
	mkdir -p $(RESOURCES_BIN)
	cp bin/macos/cdparanoia $(RESOURCES_BIN)/cdparanoia
	chmod +x $(RESOURCES_BIN)/cdparanoia

dev:
	wails dev

# Create python/.venv and install Demucs / faster-whisper / alignment deps (requires uv or python3).
lyrics-sync-python:
	@chmod +x scripts/setup-lyrics-sync-python.sh 2>/dev/null || true
	@./scripts/setup-lyrics-sync-python.sh

clean:
	rm -rf build/bin

# 軽量（IGNORE/lyrics.txt・*.flac があればそれも検証）。
test-lyrics-sync:
	cd python && python3 -m pytest tests/ -m "not heavy" -v

# 重い: Demucs + Whisper。IGNORE に lyrics.txt と FLAC を置き、次を指定して実行してください。
#   export UX_MUSIC_IGNORE_INTEGRATION=1
#   （任意） export UX_MUSIC_IGNORE_TEST_WHISPER_MODEL=base
test-lyrics-sync-ignore-e2e:
	cd python && UX_MUSIC_IGNORE_INTEGRATION=1 python3 -m pytest tests/test_ignore_pipeline_integration.py -m heavy -v --tb=short
