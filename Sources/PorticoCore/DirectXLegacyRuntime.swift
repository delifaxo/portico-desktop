import Foundation

/// Optional legacy prerequisites, downloaded only by the explicit UI action.
/// The June 2010 Microsoft package contains both x86 and x64 libraries.
public enum DirectXLegacyRuntime {
    public static let url = URL(string: "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe")!
    public static let informationURL = URL(string: "https://www.microsoft.com/en-us/download/details.aspx?id=8109")!
    public static let sha256 = "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"
    public static let bytes: Int64 = 100_275_120

    public static func download(using downloader: RuntimeInstaller, root: URL,
                                progress: @escaping @Sendable (InstallProgress) -> Void) async throws -> URL {
        try await downloader.downloadArtifact(url: url, sha256: sha256, expectedBytes: bytes,
            destination: root.appendingPathComponent("Downloads/directx_Jun2010_redist.exe"), progress: progress)
    }

    /// The trusted, pinned self-extracting CAB is unpacked without executing it.
    /// DXSETUP itself is later run by the selected Wine, with its normal license UI.
    static func extract(_ archive: URL, to directory: URL) async throws -> URL {
        try RuntimeInstaller.verifyArtifact(at: archive, sha256: sha256, expectedBytes: bytes)
        let listing = try await InstallerCommand.run("/usr/bin/tar", arguments: ["-tf", archive.path], timeout: 30)
        guard listing.status == 0 else { throw PorticoError.storage(L10n.text("Не вдалося розпакувати компоненти DirectX.")) }
        let entries = listing.output.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty, entries.count < 500, entries.contains("DXSETUP.exe"),
              entries.allSatisfy({ !$0.hasPrefix(".") && !$0.contains("/") && !$0.contains("\\") && !$0.contains(":") }) else {
            throw PorticoError.storage(L10n.text("Не вдалося розпакувати компоненти DirectX."))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let result = try await InstallerCommand.run("/usr/bin/tar", arguments: ["-xf", archive.path, "-C", directory.path], timeout: 30)
        guard result.status == 0 else { throw PorticoError.storage(L10n.text("Не вдалося розпакувати компоненти DirectX.")) }
        return directory.appendingPathComponent("DXSETUP.exe")
    }
}
