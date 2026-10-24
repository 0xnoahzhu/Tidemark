import Foundation
import System
import Testing
@testable import Tidemark

@Suite("surge-cli path check")
struct SurgeCLIPathProblemTests {
    @Test func acceptsAnExecutable() {
        #expect(SurgeCLIPathProblem(checking: "/bin/sh") == nil)
    }

    @Test func followsSymbolicLinks() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TidemarkPathCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let link = directory.appending(path: "surge-cli")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sh")
        #expect(SurgeCLIPathProblem(checking: link.path) == nil)

        let dangling = directory.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path, withDestinationPath: directory.appending(path: "nothing").path)
        #expect(SurgeCLIPathProblem(checking: dangling.path) == .missing)
    }

    @Test func reportsWhatIsWrong() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TidemarkPathCheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let plain = directory.appending(path: "surge-cli")
        try Data("#!/bin/sh\n".utf8).write(to: plain)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)

        #expect(SurgeCLIPathProblem(checking: "") == .missing)
        #expect(SurgeCLIPathProblem(checking: directory.appending(path: "missing").path) == .missing)
        #expect(SurgeCLIPathProblem(checking: plain.path + "/child") == .missing)
        #expect(SurgeCLIPathProblem(checking: directory.path) == .notAFile)
        #expect(SurgeCLIPathProblem(checking: plain.path) == .notExecutable)
        #expect(SurgeCLIPathProblem.notExecutable.message == "This file is not executable.")
    }
}
