import Foundation
import Darwin

/// Test failures are ordinary unsuccessful exits, including in optimized builds.
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) -> Never {
    FileHandle.standardError.write(Data("FAIL \(file):\(line): \(message)\n".utf8))
    exit(1)
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "check failed",
            file: StaticString = #filePath, line: UInt = #line) {
    if !condition { fail(message(), file: file, line: line) }
}
