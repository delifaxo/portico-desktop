import Foundation

/// Pinned upstream artifacts. Updating requires reviewing the release and checksum.
public enum RuntimeCatalog {
    public static let wine = RuntimeRelease(
        id: "wine-stable-11.0_1", name: "Wine Stable", version: "11.0_1",
        downloadURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
        sha256: "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388",
        downloadBytes: 185_303_032, archiveRoot: "Wine Stable.app",
        executableRelativePath: "Contents/Resources/wine/bin/wine",
        sourceURL: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.0_1")!
    )
    public static let gstreamerVersion = "1.28.1"
    public static let gstreamerURL = URL(string: "https://gstreamer.freedesktop.org/data/pkg/osx/1.28.1/gstreamer-1.0-1.28.1-universal.pkg")!
    public static let gstreamerSHA256 = "02803f73435daabe8fb12b79c38c6775d0efb83af001474558ba25c4f874d305"
    public static let gstreamerBytes: Int64 = 151_846_922
}
