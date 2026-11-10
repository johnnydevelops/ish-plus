//
//  DistroManager.swift
//  iSH+
//
//  Linux distributions for the VM. Each one is a disk image (sparse, ext4)
//  in Documents/VM/distros/<id>/. A new distribution is a downloaded root
//  filesystem archive: the next time the VM starts, the guest's initramfs
//  formats the disk and unpacks the archive (see tools/guest/boot/init), and
//  reports "ishplus: installed" on the serial port, after which the archive
//  is deleted. Every distribution boots with iSH+'s own init from the support
//  disk, so the kernel side is shared.
//
//  Sources: images.linuxcontainers.org (daily arm64 root filesystems of most
//  distributions) and armtix.artixlinux.org (Artix Linux's ARM port).
//

import CryptoKit
import Foundation

@objc(ISHDistro)
public final class Distro: NSObject, Codable {
    @objc public let id: String
    /// "Debian"
    @objc public let name: String
    /// "trixie"
    @objc public let version: String
    let source: URL
    /// "debian", for its logo (nil for distributions added by older builds)
    @objc public internal(set) var family: String?
    /// The guest has unpacked the archive onto the disk.
    @objc public internal(set) var installed: Bool
    let added: Date

    init(id: String, name: String, version: String, source: URL, installed: Bool) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.installed = installed
        added = Date()
    }

    @objc public var title: String { version.isEmpty ? name : "\(name) \(version)" }
    var directory: URL { DistroManager.directory.appendingPathComponent(id) }
    var diskURL: URL { directory.appendingPathComponent("disk.img") }
    /// The root filesystem archive, until the guest has installed it.
    var archiveURL: URL { directory.appendingPathComponent("rootfs.archive") }
    /// The account to create, until the guest has installed it.
    var setupURL: URL { directory.appendingPathComponent("setup.conf") }
    var hasArchive: Bool { FileManager.default.fileExists(atPath: archiveURL.path) }
    /// Space the disk takes (it is sparse).
    var diskUsage: Int64 {
        guard let values = try? diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
}

/// One downloadable root filesystem.
public struct DistroImage: Hashable {
    public let family: String
    public let name: String
    public let release: String
    /// "LTS", "testing"...
    public var note: String?
    /// A development or rolling snapshot rather than a release.
    public var isDevelopment = false
    public let url: URL
    /// A file listing "sha256  filename" lines, and the name to look up.
    let checksums: URL?
    let checksumName: String

    public var title: String { "\(name) \(release)" }
}

public struct DistroFamily {
    /// "debian" (also the name of its logo in Assets.xcassets/Distros)
    public let key: String
    public let name: String
    public let summary: String
    /// Releases first (newest first), development snapshots last.
    public let images: [DistroImage]
}

/// The account created when a distribution is installed.
public struct DistroSetup {
    public var user: String
    public var password: String
    public var rootPassword: String

    public init(user: String, password: String, rootPassword: String) {
        self.user = user
        self.password = password
        self.rootPassword = rootPassword
    }

    /// Valid Linux user names (as useradd accepts by default).
    public static func isValid(user: String) -> Bool {
        user.range(of: "^[a-z_][a-z0-9_-]{0,31}$", options: .regularExpression) != nil && user != "root"
    }

    /// Read by the guest's installer (tools/guest/boot/init), attached as a
    /// disk, hence padded to whole sectors.
    var file: Data {
        func line(_ key: String, _ value: String) -> String {
            "\(key)=\(Data(value.utf8).base64EncodedString())\n"
        }
        var text = line("ISHPLUS_USER", user) + line("ISHPLUS_PASSWORD", password)
            + line("ISHPLUS_ROOT_PASSWORD", rootPassword)
        text += String(repeating: "\n", count: (512 - text.utf8.count % 512) % 512)
        return Data(text.utf8)
    }
}

/// Progress of a distribution being downloaded.
public struct DistroDownload {
    public var received: Int64
    public var expected: Int64
    public var verifying = false
    public var fraction: Double { expected > 0 ? Double(received) / Double(expected) : 0 }
}

@objc(ISHDistroManager)
public final class DistroManager: NSObject, URLSessionDownloadDelegate {
    @objc public static let shared = DistroManager()
    /// Posted on the main queue when distributions or downloads change.
    @objc public static let didChangeNotification = Notification.Name("ISHDistrosDidChange")

    static var directory: URL {
        VirtualMachine.guestDirectory.appendingPathComponent("distros")
    }
    private static var listURL: URL { directory.appendingPathComponent("distros.json") }
    private static let activeKey = "Active Distro"
    /// Virtual size of a distribution's disk; it only takes the space used.
    private static let diskSize: Int64 = 32 << 30

    @objc public private(set) var distros: [Distro] = []
    /// In progress, by distribution id.
    public private(set) var downloads: [String: DistroDownload] = [:]
    private var tasks: [Int: (distro: Distro, image: DistroImage)] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
    private var lastProgressPost = Date.distantPast

    private override init() {
        super.init()
        load()
        migrateLegacyDisk()
    }

    // MARK: Installed distributions

    @objc public var active: Distro? {
        let id = UserDefaults.standard.string(forKey: Self.activeKey)
        return distros.first { $0.id == id && downloads[$0.id] == nil }
    }

    /// Whether the VM has a distribution to boot.
    @objc public var hasBootableDistro: Bool {
        guard let active else { return false }
        return active.installed || active.hasArchive
    }

    @objc public func setActive(_ distro: Distro) {
        UserDefaults.standard.set(distro.id, forKey: Self.activeKey)
        changed()
    }

    @objc public func remove(_ distro: Distro) {
        if let task = tasks.first(where: { $0.value.distro.id == distro.id }) {
            session.getAllTasks { $0.first { $0.taskIdentifier == task.key }?.cancel() }
            tasks[task.key] = nil
        }
        downloads[distro.id] = nil
        try? FileManager.default.removeItem(at: distro.directory)
        distros.removeAll { $0.id == distro.id }
        if UserDefaults.standard.string(forKey: Self.activeKey) == distro.id {
            UserDefaults.standard.set(distros.first { downloads[$0.id] == nil }?.id, forKey: Self.activeKey)
        }
        save()
        changed()
    }

    /// Called when the guest reports it unpacked the active distribution.
    func markInstalled(_ distro: Distro) {
        DispatchQueue.main.async { [self] in
            distro.installed = true
            try? FileManager.default.removeItem(at: distro.archiveURL)
            try? FileManager.default.removeItem(at: distro.setupURL)
            save()
            changed()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.listURL),
              let list = try? JSONDecoder().decode([Distro].self, from: data) else { return }
        // Downloads interrupted by the app ending are dropped.
        distros = list.filter { $0.installed || $0.hasArchive }
        if distros.count != list.count {
            for distro in list where !distros.contains(distro) {
                try? FileManager.default.removeItem(at: distro.directory)
            }
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(distros) {
            try? data.write(to: Self.listURL, options: .atomic)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// The Alpine disk earlier builds of iSH+ used (Documents/VM/rootfs.img)
    /// becomes an installed distribution.
    private func migrateLegacyDisk() {
        let legacy = VirtualMachine.guestDirectory.appendingPathComponent("rootfs.img")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let distro = Distro(id: UUID().uuidString, name: "Alpine Linux", version: "3.24",
                            source: URL(string: "https://alpinelinux.org")!, installed: true)
        distro.family = "alpine"
        do {
            try FileManager.default.createDirectory(at: distro.directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: legacy, to: distro.diskURL)
        } catch {
            vmLog("could not migrate rootfs.img: \(error)")
            return
        }
        distros.append(distro)
        if active == nil { UserDefaults.standard.set(distro.id, forKey: Self.activeKey) }
        save()
        // Files only the old setup used
        for name in ["vmlinuz", "initramfs", "modloop", "support.img"] {
            try? FileManager.default.removeItem(at: VirtualMachine.guestDirectory.appendingPathComponent(name))
        }
    }

    // MARK: Catalog

    private static let lxc = URL(string: "https://images.linuxcontainers.org")!
    private static let armtix = URL(string: "https://armtix.artixlinux.org/images/")!

    private static let familyNames = [
        "almalinux": "AlmaLinux", "alpine": "Alpine Linux", "alt": "ALT Linux", "archlinux": "Arch Linux",
        "artix": "Artix Linux", "centos": "CentOS Stream", "debian": "Debian", "devuan": "Devuan",
        "fedora": "Fedora", "kali": "Kali Linux", "openeuler": "openEuler", "opensuse": "openSUSE",
        "oracle": "Oracle Linux", "rockylinux": "Rocky Linux", "ubuntu": "Ubuntu", "voidlinux": "Void Linux",
    ]
    /// Images that do not work with iSH+'s init (they need their own to set
    /// up the system) or are not general-purpose distributions.
    private static let unsupported: Set<String> = ["busybox", "nixos", "openwrt"]
    private static let summaries = [
        "almalinux": "Enterprise Linux, compatible with RHEL",
        "alpine": "Small, simple and fast to install",
        "alt": "Russian distribution with its own packages",
        "archlinux": "Rolling release, simple and up to date",
        "artix": "Arch without systemd",
        "centos": "The upstream of RHEL",
        "debian": "The universal operating system",
        "devuan": "Debian without systemd",
        "fedora": "Leading-edge, from the Fedora Project",
        "kali": "Security testing and penetration tools",
        "openeuler": "Enterprise Linux from the OpenAtom Foundation",
        "opensuse": "Stable Leap or rolling Tumbleweed",
        "oracle": "Enterprise Linux from Oracle",
        "rockylinux": "Enterprise Linux, compatible with RHEL",
        "ubuntu": "Popular and well supported",
        "voidlinux": "Independent, with runit and xbps",
    ]
    /// Release names shown with their version, and notes.
    private static let releaseNames = [
        "ubuntu/jammy": ("22.04 Jammy Jellyfish", "LTS"), "ubuntu/noble": ("24.04 Noble Numbat", "LTS"),
        "ubuntu/plucky": ("25.04 Plucky Puffin", nil), "ubuntu/questing": ("25.10 Questing Quokka", nil),
        "ubuntu/resolute": ("26.04 Resolute Raccoon", "LTS"), "ubuntu/stonking": ("26.10 Stonking", nil),
        "debian/bookworm": ("12 bookworm", "oldstable"), "debian/trixie": ("13 trixie", "stable"),
        "debian/forky": ("14 forky", "testing"),
        "devuan/daedalus": ("5 daedalus", nil), "devuan/excalibur": ("6 excalibur", nil),
        "opensuse/tumbleweed": ("Tumbleweed", "rolling"),
        "archlinux/current": ("Rolling", nil), "voidlinux/current": ("Rolling", nil),
        "kali/current": ("Rolling", nil), "alt/Sisyphus": ("Sisyphus", "development"),
    ] as [String: (String, String?)]
    private static let development: Set<String> = ["alpine/edge", "debian/forky", "alt/Sisyphus", "ubuntu/stonking"]

    /// Available distributions, Alpine (small, the default) first.
    public func catalog() async throws -> [DistroFamily] {
        async let lxcImages = lxcCatalog()
        let artix = (try? await artixCatalog()) ?? []
        let images = try await lxcImages + artix
        let families = Dictionary(grouping: images, by: \.family).map { key, images in
            DistroFamily(key: key, name: images[0].name, summary: Self.summaries[key] ?? "",
                         images: images.sorted {
                             if $0.isDevelopment != $1.isDevelopment { return !$0.isDevelopment }
                             return $0.release.localizedStandardCompare($1.release) == .orderedDescending
                         })
        }
        return families.sorted {
            if $0.name == "Alpine Linux" { return true }
            if $1.name == "Alpine Linux" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func lxcCatalog() async throws -> [DistroImage] {
        let (data, _) = try await URLSession.shared.data(from: Self.lxc.appendingPathComponent("meta/1.0/index-system"))
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            // distribution;release;architecture;variant;serial;path
            let fields = line.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, fields[2] == "arm64", fields[3] == "default",
                  !Self.unsupported.contains(fields[0]) else { return nil }
            let family = fields[0]
            let directory = Self.lxc.appendingPathComponent(fields[5])
            let key = "\(family)/\(fields[1])"
            let (release, note) = Self.releaseNames[key] ?? (fields[1] == "edge" ? "Edge" : fields[1], nil)
            var image = DistroImage(family: family, name: Self.familyNames[family] ?? family.capitalized,
                                    release: release,
                                    url: directory.appendingPathComponent("rootfs.tar.xz"),
                                    checksums: directory.appendingPathComponent("SHA256SUMS"),
                                    checksumName: "rootfs.tar.xz")
            image.isDevelopment = Self.development.contains(key)
            image.note = note ?? (image.isDevelopment ? "development" : nil)
            return image
        }
    }

    private func artixCatalog() async throws -> [DistroImage] {
        let (data, _) = try await URLSession.shared.data(from: Self.armtix)
        let html = String(decoding: data, as: UTF8.self)
        // armtix-openrc-20260921.tar.xz: the newest one (the init system
        // does not matter, iSH+ uses its own)
        let regex = try NSRegularExpression(pattern: #"armtix-openrc-(\d{8})\.tar\.xz"#)
        let dates = regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
        guard let date = dates.max() else { return [] }
        let file = "armtix-openrc-\(date).tar.xz"
        return [DistroImage(family: "artix", name: "Artix Linux", release: "Rolling",
                            url: Self.armtix.appendingPathComponent(file),
                            checksums: Self.armtix.appendingPathComponent("sha256sums"),
                            checksumName: file)]
    }

    /// The download size, for asking before downloading.
    public func size(of image: DistroImage) async -> Int64? {
        var request = URLRequest(url: image.url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength
    }

    // MARK: Downloading

    /// Starts downloading a distribution; it appears in `distros` at once.
    @discardableResult
    public func install(_ image: DistroImage, setup: DistroSetup?) -> Distro {
        let distro = Distro(id: UUID().uuidString, name: image.name, version: image.release,
                            source: image.url, installed: false)
        distro.family = image.family
        try? FileManager.default.createDirectory(at: distro.directory, withIntermediateDirectories: true)
        if let setup {
            // Only readable by iSH+, and deleted once the guest has used it
            try? setup.file.write(to: distro.setupURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        distros.append(distro)
        downloads[distro.id] = DistroDownload(received: 0, expected: 0)
        let task = session.downloadTask(with: image.url)
        tasks[task.taskIdentifier] = (distro, image)
        task.resume()
        changed()
        return distro
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let (distro, _) = tasks[downloadTask.taskIdentifier] else { return }
        downloads[distro.id] = DistroDownload(received: totalBytesWritten, expected: totalBytesExpectedToWrite)
        if Date().timeIntervalSince(lastProgressPost) > 0.25 {
            lastProgressPost = Date()
            changed()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let (distro, _) = tasks[downloadTask.taskIdentifier] else { return }
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            return // reported in didCompleteWithError
        }
        // The file is deleted when this returns: move it first.
        do {
            try FileManager.default.createDirectory(at: distro.directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: distro.archiveURL)
            try FileManager.default.moveItem(at: location, to: distro.archiveURL)
        } catch {
            vmLog("could not keep the download of \(distro.title): \(error)")
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (distro, image) = tasks.removeValue(forKey: task.taskIdentifier) else { return }
        var failure = error?.localizedDescription
        if failure == nil, let response = task.response as? HTTPURLResponse, response.statusCode != 200 {
            failure = "The server answered \(response.statusCode)."
        }
        if failure == nil && !distro.hasArchive {
            failure = "The download could not be saved."
        }
        if let failure {
            fail(distro, failure)
            return
        }
        downloads[distro.id]?.verifying = true
        changed()
        Task.detached(priority: .userInitiated) { [self] in
            let problem = await prepare(distro, image)
            await MainActor.run {
                if let problem {
                    fail(distro, problem)
                    return
                }
                downloads[distro.id] = nil
                if active == nil { UserDefaults.standard.set(distro.id, forKey: Self.activeKey) }
                save()
                changed()
            }
        }
    }

    /// Checks the archive against the published checksum and creates the
    /// (empty, sparse) disk. Returns a problem, or nil.
    private func prepare(_ distro: Distro, _ image: DistroImage) async -> String? {
        if let checksums = image.checksums,
           let (data, _) = try? await URLSession.shared.data(from: checksums) {
            let expected = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, parts.last!.trimmingCharacters(in: CharacterSet(charactersIn: "*")) == image.checksumName
                else { return nil }
                return parts[0].lowercased()
            }.first
            if let expected, let actual = Self.sha256(of: distro.archiveURL), actual != expected {
                return "The download is damaged (its checksum does not match). Try again."
            }
        }
        do {
            FileManager.default.createFile(atPath: distro.diskURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: distro.diskURL)
            try handle.truncate(atOffset: UInt64(Self.diskSize))
            try handle.close()
        } catch {
            return "Could not create the disk: \(error.localizedDescription)"
        }
        return nil
    }

    private func fail(_ distro: Distro, _ message: String) {
        vmLog("download of \(distro.title) failed: \(message)")
        downloads[distro.id] = nil
        try? FileManager.default.removeItem(at: distro.directory)
        distros.removeAll { $0.id == distro.id }
        save()
        changed()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self,
                                        userInfo: ["error": "\(distro.title) could not be downloaded. \(message)"])
    }

    private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
