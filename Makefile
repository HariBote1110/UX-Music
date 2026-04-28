APP_BUNDLE = build/bin/UX-Music.app
RESOURCES_BIN = $(APP_BUNDLE)/Contents/Resources/bin
SWIFT_SIDECAR_BIN = swift/lyrics-sync/.build/release/lyrics-sync-swift

.PHONY: build dev clean lyrics-sync-python test test-go test-renderer test-python test-lyrics-sync test-lyrics-sync-ignore-e2e

# ローカルで CI と同じテストを回すための導線。
# CI 側の定義は .github/workflows/test.yml。
test: test-go test-renderer test-python

# cmd/spike-* は CoreAudio 依存の macOS 専用スパイク、
# node_modules 配下は依存パッケージ同梱の Go コードなので除外する。
# root パッケージの go:embed を満たすため renderer の dist が必要。
test-go:
	cd src/renderer && npm run build
	go test -race -count=1 $$(go list ./... | grep -v node_modules | grep -v '/cmd/spike-')

test-renderer:
	cd src/renderer && npm run typecheck && npm run test

test-python:
	python3 -m pytest python/tests

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

# 軽量（IGNORE/lyrics.txt・*.flac があればそれも検証）。
test-lyrics-sync:
	cd python && python3 -m pytest tests/ -m "not heavy" -v

# 重い: Demucs + Whisper。IGNORE に lyrics.txt と FLAC を置き、次を指定して実行してください。
#   export UX_MUSIC_IGNORE_INTEGRATION=1
#   （任意） export UX_MUSIC_IGNORE_TEST_WHISPER_MODEL=base
test-lyrics-sync-ignore-e2e:
	cd python && UX_MUSIC_IGNORE_INTEGRATION=1 python3 -m pytest tests/test_ignore_pipeline_integration.py -m heavy -v --tb=short
