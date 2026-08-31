import Foundation

/// A minimal assertion harness.
///
/// XCTest ships with Xcode, and this machine has only the Command Line Tools, so
/// the suite is a plain executable — the same approach VimText takes next door.
/// Everything under test is `public`, so no `@testable` import is needed and the
/// suite builds in release as well as debug.
final class Suite {
    private var failures: [String] = []
    private var passed = 0
    private var current = ""

    func test(_ name: String, _ body: () throws -> Void) {
        current = name
        do {
            try body()
        } catch {
            failures.append("\(name): threw \(error)")
        }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            passed += 1
        } else {
            failures.append("\(current): \(message())")
        }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        expect(actual == expected, "\(label) — expected \(expected), got \(actual)")
    }

    func expectClose(_ actual: Double, _ expected: Double, _ label: String,
                     tolerance: Double = 0.001) {
        expect(abs(actual - expected) <= tolerance,
               "\(label) — expected \(expected), got \(actual)")
    }

    func expectNil<T>(_ value: T?, _ label: String) {
        expect(value == nil, "\(label) — expected nil, got \(String(describing: value))")
    }

    func report(_ section: String) {
        print("  \(section)")
    }

    func finish() -> Never {
        print("")
        if failures.isEmpty {
            print("PASS — \(passed) assertions")
            exit(0)
        }
        print("FAIL — \(failures.count) failure(s), \(passed) passed")
        for failure in failures {
            print("  ✗ \(failure)")
        }
        exit(1)
    }
}
