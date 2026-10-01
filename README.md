# iceKast

A free macOS app that makes running an [Icecast](https://icecast.org) streaming server easy.
Built for Radiologik users, but works with any encoder (BUTT, Audio Hijack, LadioCast…).
Icecast is bundled; nothing else needs to be installed. MP3, AAC and HE-AAC streams.

## Building

Requires Xcode, and `xcodegen` (`brew install xcodegen`) to generate the project.

```bash
scripts/build-icecast.sh     # builds the universal static Icecast into build/icecast
xcodegen generate            # creates iceKast.xcodeproj from project.yml
xcodebuild -project iceKast.xcodeproj -scheme iceKast -derivedDataPath build/xcode build
xcodebuild -project iceKast.xcodeproj -scheme iceKast -derivedDataPath build/xcode test
```

## License

GPLv2, same as Icecast. See [LICENSE](LICENSE).
