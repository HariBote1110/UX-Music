DEVICE_UDID := 00008150-001A55A63C07801C
BUNDLE_ID   := com.uxlabs.uxMusicMobile

.PHONY: run run-release install-debug install-release launch

## flutter run (debug, hot-reload)
run:
	flutter run -d $(DEVICE_UDID)

## build release + install + launch via devicectl (avoids flutter install lock issue)
run-release: install-release launch

install-debug:
	flutter build ios && \
	xcrun devicectl device install app --device $(DEVICE_UDID) build/ios/Debug-iphoneos/Runner.app

install-release:
	flutter build ios --release && \
	xcrun devicectl device install app --device $(DEVICE_UDID) build/ios/Release-iphoneos/Runner.app

launch:
	xcrun devicectl device process launch --device $(DEVICE_UDID) $(BUNDLE_ID)
