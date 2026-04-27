APP_BUNDLE = build/bin/UX-Music.app
RESOURCES_BIN = $(APP_BUNDLE)/Contents/Resources/bin

.PHONY: build dev clean

build:
	wails build
	mkdir -p $(RESOURCES_BIN)
	cp bin/macos/cdparanoia $(RESOURCES_BIN)/cdparanoia
	chmod +x $(RESOURCES_BIN)/cdparanoia

dev:
	wails dev

clean:
	rm -rf build/bin
