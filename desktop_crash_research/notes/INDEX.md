# desktop_crash_research ノート索引

新しいものが上。

- [mtp-libusb-context-leak.md](mtp-libusb-context-leak.md) — 定期クラッシュ（起動7h50m後にexit 2）の原因を特定。MTP監視が毎分SelectDeviceでlibusb_initしlibusb_exitしないためpthread TLSキー(上限512)が枯渇しabort。再現で確定
