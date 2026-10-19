import Foundation
import Darwin
import SystemLock

// Keep one writer per library across installed and development copies of the app.
final class LibraryAccessLock {
    private let descriptor: Int32
    init(directory: URL) throws {
        let path = directory.appendingPathComponent("writer.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard shiguang_try_exclusive_lock(fd) == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == EWOULDBLOCK {
                throw NSError(domain: "LumaTrace", code: 4, userInfo: [NSLocalizedDescriptionKey: "另一个LumaTrace正在使用此资料库。请退出其他LumaTrace应用（⌘Q）后，重新打开。"])
            }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }
}
