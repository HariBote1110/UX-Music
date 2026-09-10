APP_BUNDLE = build/bin/UX-Music.app
RESOURCES_BIN = $(APP_BUNDLE)/Contents/Resources/bin

.PHONY: build dev clean test test-go test-renderer

# ローカルで CI と同じテストを回すための導線。
# CI 側の定義は .github/workflows/test.yml。
test: test-go test-renderer

# cmd/spike-* は CoreAudio 依存の macOS 専用スパイク、
# node_modules 配下は依存パッケージ同梱の Go コードなので除外する。
# root パッケージの go:embed を満たすため renderer の dist が必要。
test-go:
	cd src/renderer && npm run build
	go test -race -count=1 $$(go list ./... | grep -v node_modules | grep -v '/cmd/spike-')

test-renderer:
	cd src/renderer && npm run typecheck && npm run test

build:
	wails build
	mkdir -p $(RESOURCES_BIN)
	cp bin/macos/cdparanoia $(RESOURCES_BIN)/cdparanoia
	chmod +x $(RESOURCES_BIN)/cdparanoia
	# libcdio* など、残る非システム dylib を一般的に同梱する。
	# sidecar を配置した後に実行し、Contents/Resources/bin も走査する。
	bash scripts/vendor-native-dylibs.sh $(APP_BUNDLE)

dev:
	wails dev

clean:
	rm -rf build/bin
