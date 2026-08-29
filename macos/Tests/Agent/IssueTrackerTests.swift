import Foundation
import Testing
@testable import trm

struct IssueTrackerTests {
    @Test func parsesFlexibleStatusSpacingAndKeepsIndexOrder() {
        let index = """
        SECTION 1 — ENGINE

        E-01  First issue                                      DEPLOYED
              The first report paragraph.

        F-08  A title whose status has only one separating space STAGED
              The spacing in this real tracker row is unusual but valid.

        SECTION 2 — OPEN

        O-01  Third issue OPEN
              Still needs work.
        """
        let documents: [String: (content: String, modifiedAt: TimeInterval)] = [
            "E-01": ("# E-01 — First issue\n\n**Status:** DEPLOYED", 1),
            "F-08": ("# F-08 — Drift\n\n**Status:** STAGED", 2),
            "O-01": ("# O-01 — Third issue\n\n**Status:** OPEN", 3),
        ]

        let issues = IssueTrackerParser.parse(
            index: index, documents: documents, artifacts: [])

        #expect(issues.map(\.id) == ["E-01", "F-08", "O-01"])
        #expect(issues.map(\.status) == [.deployed, .staged, .open])
        #expect(issues[1].title == "A title whose status has only one separating space")
        #expect(issues[1].report.contains("unusual but valid"))
    }

    @Test func attachesArtifactsOnlyToTheirOwnIssueAndFlagsStatusDrift() {
        let index = "O-01  One issue OPEN"
        let artifacts = [
            IssueArtifact(
                relativePath: "issues/artifacts/O-01/screenshot.png",
                name: "screenshot.png", size: 10, modifiedAt: 10, kind: .image),
            IssueArtifact(
                relativePath: "issues/artifacts/O-02/other.png",
                name: "other.png", size: 10, modifiedAt: 11, kind: .image),
        ]
        let issues = IssueTrackerParser.parse(
            index: index,
            documents: ["O-01": ("# O-01 — One\n\n**Status:** STAGED", 5)],
            artifacts: artifacts)

        #expect(issues.count == 1)
        #expect(issues[0].artifacts.map(\.name) == ["screenshot.png"])
        #expect(issues[0].statusIsOutOfSync)
        #expect(issues[0].mostRecentChange == 10)
    }

    @Test func issueIDsMatchAsTokensRatherThanSubstrings() {
        #expect(IssueTrackerModel.containsIssueID("O-01", in: "Working on O-01 now"))
        #expect(IssueTrackerModel.containsIssueID("o-01", in: "[Issue O-01] continue"))
        #expect(!IssueTrackerModel.containsIssueID("O-01", in: "Working on O-010 now"))
        #expect(!IssueTrackerModel.containsIssueID("O-01", in: "prefixO-01suffix"))
    }

    @Test func projectContainmentDoesNotConfuseSiblingPrefixes() {
        #expect(IssueTrackerModel.path("/Users/g/dev/fasmac", isWithin: "/Users/g/dev/fasmac"))
        #expect(IssueTrackerModel.path("/Users/g/dev/fasmac/backend", isWithin: "/Users/g/dev/fasmac"))
        #expect(!IssueTrackerModel.path("/Users/g/dev/fasmac-old", isWithin: "/Users/g/dev/fasmac"))
    }

    @Test func appendsResponsesToTheIssueWorkingFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trm-issue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("issues", isDirectory: true),
            withIntermediateDirectories: true)
        let project = IssueTrackerProject(
            rootPath: root.path, indexFileName: "issues.md", remoteHost: nil)
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let relative = try IssueTrackerStore.appendResponse(
            project: project,
            issueID: "O-01",
            text: "Keep the regression test and explain the migration.",
            delivery: "forwarded to Codex in fasmac",
            now: date)

        #expect(relative == "issues/artifacts/O-01/responses.md")
        let content = try String(
            contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        #expect(content.contains("# Issue responses — O-01"))
        #expect(content.contains("Keep the regression test"))
        #expect(content.contains("forwarded to Codex in fasmac"))
    }
}
