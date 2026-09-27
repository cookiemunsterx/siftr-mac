import Foundation

/// One Siftr per data folder. Two copies on the same database (another
/// build, or the same one started twice) would both write to it and both
/// write out lyrics. The first to start holds `<folder>/.lock` for as long as
/// it runs -- macOS lets go of it when the app quits or crashes -- with its
/// process number inside, so a second copy knows which one to hand over to.
public final class InstanceLock {
    public enum Outcome {
        case acquired(InstanceLock)
        case heldBy(pid_t?)               // another copy has it (its process number, if it wrote one)
        case unavailable                  // the folder can't be written: carry on without a lock
    }

    private let fd: Int32

    private init(fd: Int32) { self.fd = fd }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }

    public static func acquire(in folder: URL) -> Outcome {
        let path = folder.appendingPathComponent(".lock").path
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return .unavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            var buffer = [UInt8](repeating: 0, count: 32)
            let n = pread(fd, &buffer, buffer.count, 0)
            close(fd)
            let text = n > 0 ? String(decoding: buffer.prefix(n), as: UTF8.self) : ""
            return .heldBy(pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let pid = Array("\(getpid())\n".utf8)
        ftruncate(fd, 0)
        _ = pwrite(fd, pid, pid.count, 0)
        return .acquired(InstanceLock(fd: fd))
    }
}
