import Darwin
import Foundation
import SesameEngine

/// One `folders` line made into the list of photos the index must hold.
enum Reconcile {
    /// Every admitted photo under the folders, each file once (folders may overlap, and a path may be spelled two ways
    /// or be a hard link), with the device it is on, and the paths the walk could not look at: a folder it could not
    /// list, or a photo whose bytes are in the cloud. The index keeps the rows at or below those paths. A folder that
    /// does not exist counts as empty: its rows go (design section 14, Q4). One file is one device and inode; the first
    /// path in sorted order wins (design D7).
    static func photos(in folders: [HelperFolder]) -> (found: [(file: WalkedFile, device: Int64)], unreadable: [String]) {
        var byPath: [String: WalkedFile] = [:]
        var unreadable: [String] = []
        for folder in folders {
            let scan = Walker.scan(root: folder.path, mode: .read, picks: folders)
            unreadable += scan.unreadable + scan.dataless
            for file in scan.files { byPath[file.path] = file }
        }
        var seen = Set<[Int64]>()
        var found: [(file: WalkedFile, device: Int64)] = []
        for path in byPath.keys.sorted() {
            var info = stat()
            guard lstat(path, &info) == 0, let file = byPath[path] else { continue }
            let device = Int64(info.st_dev)
            if seen.insert([device, Int64(bitPattern: UInt64(info.st_ino))]).inserted { found.append((file, device)) }
        }
        return (found, unreadable)
    }
}
