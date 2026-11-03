import Foundation
import Darwin

/// An expected probe failure must not enter Swift's crash reporter.
struct ProbeCheck {
    let name: String
    let cleanup: () -> Void

    init(_ name: String, cleanup: @escaping () -> Void = {}) {
        self.name = name
        self.cleanup = cleanup
    }

    func callAsFunction(_ condition: Bool, _ message: @autoclosure () -> String = "check failed",
                        file: StaticString = #filePath, line: UInt = #line) {
        if !condition { fail(message(), file: file, line: line) }
    }

    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
        FileHandle.standardError.write(Data("\(name): FAIL \(file):\(line): \(message)\n".utf8))
        cleanup()
        exit(1)
    }

    func attempt<T>(file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> T) -> T {
        do { return try body() }
        catch { fail(error.localizedDescription, file: file, line: line) }
    }
}
