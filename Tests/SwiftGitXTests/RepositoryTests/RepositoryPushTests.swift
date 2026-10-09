import Foundation
import SwiftGitX
import Testing
#if os(macOS)
import Darwin
#endif

@Suite("Repository - Push", .tags(.repository, .operation, .push))
final class RepositoryPushTests: SwiftGitXTest {
    @Test("Push to remote repository")
    func pushToRemote() async throws {
        let remoteRepository = mockRepository(suffix: "--remote", isBare: true)
        let seedRepository = mockRepository(suffix: "--seed")
        try seedRepository.remote.add(named: "origin", at: remoteRepository.path)
        try seedRepository.mockCommit(message: "Initial commit")
        try await seedRepository.push()

        // Clone the remote repository to the local repository
        let localDirectory = mockDirectory(suffix: "--local")
        let localRepository = try await Repository.clone(from: remoteRepository.path, to: localDirectory)

        // Create a new commit in the local repository
        try localRepository.mockCommit(message: "Pushed commit", file: localRepository.mockFile(name: "PushedFile.md"))

        // Push the commit to the remote repository
        try await localRepository.push()

        // Check if the commit is pushed
        #expect(try localRepository.HEAD.target.id == remoteRepository.HEAD.target.id)
    }

    @Test("Explicit branch push targets a non-current branch")
    func pushExplicitNonCurrentBranch() async throws {
        let remoteRepository = mockRepository(suffix: "--remote", isBare: true)
        let localRepository = mockRepository(suffix: "--local")
        try localRepository.remote.add(named: "origin", at: remoteRepository.path)

        let mainCommit = try localRepository.mockCommit(message: "main")
        let main = try localRepository.branch.current
        let mainName = main.name
        let origin = try #require(localRepository.remote["origin"])
        try await localRepository.push(branch: main, to: origin)
        let topic = try localRepository.branch.create(named: "topic", from: main)
        try localRepository.switch(to: topic)
        let topicFile = try localRepository.mockFile(name: "topic.txt")
        try localRepository.add(file: topicFile)
        let topicCommit = try localRepository.commit(message: "topic")
        try localRepository.switch(to: main)
        #expect(topicCommit.id != mainCommit.id)

        try await localRepository.push(branch: topic, to: origin)

        #expect(try remoteRepository.reference.get(named: "refs/heads/topic").target.id == topicCommit.id)
        #expect(try remoteRepository.reference.get(named: "refs/heads/\(mainName)").target.id == mainCommit.id)
    }

    @Test("Explicit normal push rejects a non-fast-forward update")
    func normalPushRejectsNonFastForward() async throws {
        let (local, writer, remote, branch, _) = try await makeDivergedRepositories(suffix: "--normal")
        let remoteBefore = try remote.branch.get(named: branch.name).target.id
        let origin = try #require(local.remote["origin"])

        await #expect(throws: SwiftGitXError.self) {
            try await local.push(branch: branch, to: origin)
        }

        #expect(try remote.branch.get(named: branch.name).target.id == remoteBefore)
        #expect(try writer.HEAD.target.id == remoteBefore)
    }

    @Test("Explicit force push updates a non-fast-forward destination")
    func explicitForcePush() async throws {
        let (local, _, remote, branch, _) = try await makeDivergedRepositories(suffix: "--force")
        let origin = try #require(local.remote["origin"])

        try await local.push(branch: branch, to: origin, strategy: .force)

        #expect(try remote.branch.get(named: branch.name).target.id == local.HEAD.target.id)
    }

    @Test("Force-with-lease refuses local path transport without changing the remote")
    func forceWithLeaseRejectsUnsafeLocalTransport() async throws {
        let remote = mockRepository(suffix: "--remote", isBare: true)
        let local = mockRepository(suffix: "--local")
        try local.remote.add(named: "origin", at: remote.path)
        let commit = try local.mockCommit()
        let branch = try local.branch.current
        let origin = try #require(local.remote["origin"])
        let error = await #expect(throws: SwiftGitXError.self) {
            try await local.push(branch: branch, to: origin, strategy: .forceWithLease(expectedOID: commit.id))
        }

        #expect(error?.code == .notSupported)
        #expect(remote.branch[branch.name] == nil)
    }

    @Test("Push propagates a transport failure without changing local references")
    func pushTransportFailure() async throws {
        let local = mockRepository(suffix: "--unreachable")
        try local.remote.add(
            named: "origin",
            at: URL(string: "git://127.0.0.1:1/unavailable.git")!
        )
        let commit = try local.mockCommit()
        let branch = try local.branch.current
        let origin = try #require(local.remote["origin"])

        let error = await #expect(throws: SwiftGitXError.self) {
            try await local.push(branch: branch, to: origin)
        }

        #expect(error?.operation?.rawValue == "push")
        #expect(try local.branch.get(named: branch.name).target.id == commit.id)
    }

    #if os(macOS)
    @Test("Force-with-lease succeeds when the advertised destination matches")
    func forceWithLeaseMatchingOID() async throws {
        let remote = mockRepository(suffix: "--lease-remote", isBare: true)
        try await withGitDaemon(for: remote, receivePack: true) { remoteURL in
            let local = mockRepository(suffix: "--lease-local")
            try local.remote.add(named: "origin", at: remoteURL)
            let initial = try local.mockCommit(message: "initial")
            let branch = try local.branch.current
            let origin = try #require(local.remote["origin"])
            try await local.push(branch: branch, to: origin)

            let expectedOID = initial.id
            let updated = try local.mockCommit(message: "rewritten history")
            try await local.push(
                branch: branch,
                to: origin,
                strategy: .forceWithLease(expectedOID: expectedOID)
            )

            #expect(try remote.reference.get(named: branch.fullName).target.id == updated.id)
        }
    }

    @Test("Force-with-lease rejects a remote changed by another writer")
    func forceWithLeaseRejectsStaleOID() async throws {
        let remote = mockRepository(suffix: "--lease-stale-remote", isBare: true)
        try await withGitDaemon(for: remote, receivePack: true) { remoteURL in
            let local = mockRepository(suffix: "--lease-stale-local")
            try local.remote.add(named: "origin", at: remoteURL)
            let initial = try local.mockCommit(message: "initial")
            let branch = try local.branch.current
            let origin = try #require(local.remote["origin"])
            try await local.push(branch: branch, to: origin)

            let writer = try await Repository.clone(
                from: remoteURL,
                to: mockDirectory(suffix: "--lease-stale-writer")
            )
            let oldExpectedOID = initial.id
            try local.mockCommit(message: "local history")
            let writerCommit = try writer.mockCommit(message: "collaborator update")
            try await writer.push(
                branch: writer.branch.current,
                to: try #require(writer.remote["origin"])
            )

            let error = await #expect(throws: SwiftGitXError.self) {
                try await local.push(
                    branch: branch,
                    to: origin,
                    strategy: .forceWithLease(expectedOID: oldExpectedOID)
                )
            }

            #expect(error?.message.contains(oldExpectedOID.hex) == true)
            #expect(error?.message.contains(writerCommit.id.hex) == true)
            #expect(error?.code == .mismatch)
            #expect(try remote.reference.get(named: branch.fullName).target.id == writerCommit.id)
        }
    }

    @Test("Force-with-lease rejects an incorrect expected OID")
    func forceWithLeaseRejectsIncorrectOID() async throws {
        let remote = mockRepository(suffix: "--lease-incorrect-remote", isBare: true)
        try await withGitDaemon(for: remote, receivePack: true) { remoteURL in
            let local = mockRepository(suffix: "--lease-incorrect-local")
            try local.remote.add(named: "origin", at: remoteURL)
            let initial = try local.mockCommit(message: "initial")
            let branch = try local.branch.current
            let origin = try #require(local.remote["origin"])
            try await local.push(branch: branch, to: origin)
            let before = try remote.reference.get(named: branch.fullName).target.id
            let incorrectOID = try OID(hex: "1111111111111111111111111111111111111111")
            try local.mockCommit(message: "next")

            let error = await #expect(throws: SwiftGitXError.self) {
                try await local.push(
                    branch: branch,
                    to: origin,
                    strategy: .forceWithLease(expectedOID: incorrectOID)
                )
            }

            #expect(error?.message.contains(incorrectOID.hex) == true)
            #expect(error?.message.contains(initial.id.hex) == true)
            #expect(error?.code == .mismatch)
            #expect(try remote.reference.get(named: branch.fullName).target.id == before)
        }
    }

    @Test("Force-with-lease rejects a missing destination branch")
    func forceWithLeaseRejectsMissingBranch() async throws {
        let remote = mockRepository(suffix: "--lease-missing-remote", isBare: true)
        try await withGitDaemon(for: remote, receivePack: true) { remoteURL in
            let local = mockRepository(suffix: "--lease-missing-local")
            try local.remote.add(named: "origin", at: remoteURL)
            let commit = try local.mockCommit(message: "initial")
            let main = try local.branch.current
            let missing = try local.branch.create(named: "missing", from: main)
            let origin = try #require(local.remote["origin"])

            let error = await #expect(throws: SwiftGitXError.self) {
                try await local.push(
                    branch: missing,
                    to: origin,
                    strategy: .forceWithLease(expectedOID: commit.id)
                )
            }

            #expect(error?.message.contains("does not exist") == true)
            #expect(remote.reference[missing.fullName] == nil)
        }
    }
    #endif

    private func makeDivergedRepositories(
        suffix: String
    ) async throws -> (local: Repository, writer: Repository, remote: Repository, branch: Branch, expected: OID) {
        let remote = mockRepository(suffix: "\(suffix)--remote", isBare: true)
        let local = mockRepository(suffix: "\(suffix)--local")
        try local.remote.add(named: "origin", at: remote.path)
        let base = try local.mockCommit(message: "base")
        let branch = try local.branch.current
        let origin = try #require(local.remote["origin"])
        try await local.push(branch: branch, to: origin)

        let writerDirectory = mockDirectory(suffix: "\(suffix)--writer")
        let writer = try await Repository.clone(from: remote.path, to: writerDirectory)
        try local.mockCommit(message: "local rewrite")
        try writer.mockCommit(message: "new remote commit")
        try await writer.push(branch: writer.branch.current, to: try #require(writer.remote["origin"]))

        return (local, writer, remote, branch, base.id)
    }

    @Test("Push to empty remote and set upstream")
    func pushEmptyRemoteSetUpstream() async throws {
        // Create a mock repository at the temporary directory
        let remoteRepository = mockRepository(suffix: "--remote", isBare: true)

        // Create a mock repository at the temporary directory
        let localRepository = mockRepository(suffix: "--local")

        // Create a new commit in the local repository
        try localRepository.mockCommit(message: "Pushed commit", file: localRepository.mockFile(name: "PushedFile.md"))

        // Add remote repository to the local repository
        try localRepository.remote.add(named: "origin", at: remoteRepository.path)

        // Push the commit to the remote repository
        try await localRepository.push()

        // Update the remote-tracking ref before setting the upstream.
        try await localRepository.fetch()

        // Check if the commit is pushed
        #expect(try localRepository.HEAD.target.id == remoteRepository.HEAD.target.id)

        // Upstream branch should be nil
        #expect(try localRepository.branch.current.upstream == nil)

        // Set the upstream branch
        let currentBranchName = try localRepository.branch.current.name
        let remoteBranchName = "origin/\(currentBranchName)"
        try localRepository.branch.setUpstream(to: localRepository.branch.get(named: remoteBranchName))

        // Check if the upstream branch is set
        let upstreamBranch = try #require(localRepository.branch.current.upstream as? Branch)
        #expect(upstreamBranch.target.id == (try remoteRepository.HEAD.target.id))
        #expect(upstreamBranch.name == remoteBranchName)
        #expect(upstreamBranch.fullName == "refs/remotes/origin/\(currentBranchName)")
    }
}
