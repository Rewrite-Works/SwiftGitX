//
//  Repository+push.swift
//  SwiftGitX
//
//  Created by İbrahim Çetin on 23.11.2025.
//

import Foundation
import libgit2

/// Context retained for the synchronous libgit2 negotiation callback.
private final class PushLeaseContext {
    let expectedOID: OID
    let destination: String
    var failure: Failure?

    enum Failure {
        case missingReference
        case mismatch(actual: OID)
        case wrongDestination
    }

    init(expectedOID: OID, destination: String) {
        self.expectedOID = expectedOID
        self.destination = destination
    }
}

/// Checks the exact destination OID advertised by the remote during negotiation.
private let pushLeaseNegotiation: git_push_negotiation = { updates, count, payload in
    guard let payload,
        let updates,
        count == 1,
        let update = updates[0]
    else {
        return GIT_EUSER.rawValue
    }
    let context = Unmanaged<PushLeaseContext>.fromOpaque(payload).takeUnretainedValue()

    guard let destination = update.pointee.dst_refname,
        String(cString: destination) == context.destination
    else {
        context.failure = .wrongDestination
        return GIT_EUSER.rawValue
    }

    let actualOID = OID(raw: update.pointee.src)
    guard actualOID != .zero else {
        context.failure = .missingReference
        return GIT_EUSER.rawValue
    }
    guard actualOID == context.expectedOID else {
        context.failure = .mismatch(actual: actualOID)
        return GIT_EUSER.rawValue
    }

    return 0
}

extension Repository {
    /// Push changes of the current branch to the remote.
    ///
    /// - Parameters:
    ///   - remote: The remote to push the changes to.
    ///   - createsRefspec: If `true`, automatically creates a push refspec when none exists.
    ///     If `false`, throws an error when no matching refspec is found. Defaults to `true`.
    ///
    /// This method uses the configured refspecs to push the changes to the remote.
    ///
    /// If the remote is not specified, the upstream of the current branch is used
    /// and if the upstream branch is not found, the `origin` remote is used.
    // TODO: Implement options of these methods
    public nonisolated func push(remote: Remote? = nil, createsRefspec: Bool = true) async throws(SwiftGitXError) {
        // Get the current branch or throw an error if HEAD is detached
        let currentBranch = try branch.current

        // Get the remote or throw an error if not found
        guard let remote = remote ?? currentBranch.remote ?? self.remote["origin"] else {
            throw SwiftGitXError(code: .notFound, category: .reference, message: "Remote not found")
        }

        // Ensure a push refspec exists for the current branch
        if try !hasPushRefspec(for: currentBranch, remote: remote) {
            if createsRefspec {
                // Add a push refspec for the current branch if not exists
                try addPushRefspec(for: currentBranch, remote: remote)
            } else {
                throw SwiftGitXError(
                    code: .notFound, operation: .push, category: .reference,
                    message: "No push refspec configured for branch '\(currentBranch.name)' on remote '\(remote.name)'"
                )
            }
        }

        // Lookup the remote
        let remotePointer = try ReferenceFactory.lookupRemotePointer(name: remote.name, repositoryPointer: pointer)
        defer { git_remote_free(remotePointer) }

        // Perform the push operation using configured refspecs
        try git(operation: .push) {
            git_remote_push(remotePointer, nil, nil)
        }
    }

    /// Pushes one local branch to the same named branch on a remote.
    ///
    /// This overload targets the supplied branch directly, regardless of the current
    /// checkout, and does not change configured push refspecs.
    ///
    /// - Parameters:
    ///   - branch: The local branch whose tip will be pushed.
    ///   - remote: The remote receiving the update.
    ///   - strategy: The update policy. Defaults to ``PushStrategy/normal``.
    /// - Throws: ``SwiftGitXError`` if the branch, remote, refspec, transport, lease,
    ///   or server rejects the update. A lease mismatch message contains both OIDs.
    ///
    /// For ``PushStrategy/forceWithLease(expectedOID:)``, the remote must advertise
    /// exactly one matching destination ref with the expected OID. A missing ref is
    /// rejected. On smart Git transports, the server receives the advertised old OID
    /// and must compare it as part of its ref update, closing the negotiation-to-update
    /// race for conforming receive-pack servers. Local path transports are rejected
    /// because libgit2's local transport does not perform this old-OID comparison.
    public nonisolated func push(
        branch: Branch,
        to remote: Remote,
        strategy: PushStrategy = .normal
    ) async throws(SwiftGitXError) {
        guard branch.type == .local,
            branch.fullName.hasPrefix("refs/heads/"),
            branch.fullName.count > "refs/heads/".count
        else {
            throw SwiftGitXError(
                code: .invalidSpec, operation: .push, category: .reference,
                message: "Push requires a local branch with a valid refs/heads name"
            )
        }

        let remotePointer = try ReferenceFactory.lookupRemotePointer(name: remote.name, repositoryPointer: pointer)
        defer { git_remote_free(remotePointer) }

        let force: Bool
        let leaseContext: PushLeaseContext?
        switch strategy {
        case .normal:
            force = false
            leaseContext = nil
        case .force:
            force = true
            leaseContext = nil
        case let .forceWithLease(expectedOID):
            guard expectedOID != .zero else {
                throw SwiftGitXError(
                    code: .invalidSpec, operation: .push, category: .reference,
                    message: "A force-with-lease expected OID must identify an existing remote commit"
                )
            }
            guard !Self.isLocalTransport(remote.url) else {
                throw SwiftGitXError(
                    code: .notSupported, operation: .push, category: .net,
                    message: "Force-with-lease is unavailable for local path remotes because their libgit2 transport does not atomically compare the expected OID"
                )
            }
            force = true
            leaseContext = PushLeaseContext(expectedOID: expectedOID, destination: branch.fullName)
        }

        let refspec = "\(force ? "+" : "")\(branch.fullName):\(branch.fullName)"
        var refspecs = [refspec].gitStrArray
        defer { git_strarray_free(&refspecs) }

        if let leaseContext {
            var options = git_push_options()
            try git { git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)) }
            options.callbacks.push_negotiation = pushLeaseNegotiation
            options.callbacks.payload = Unmanaged.passUnretained(leaseContext).toOpaque()

            let status = git_remote_push(remotePointer, &refspecs, &options)
            if status < 0, let failure = leaseContext.failure {
                switch failure {
                case .missingReference:
                    throw SwiftGitXError(
                        code: .notFound, operation: .push, category: .reference,
                        message: "Force-with-lease rejected: destination reference '\(branch.fullName)' does not exist"
                    )
                case let .mismatch(actual):
                    throw SwiftGitXError(
                        code: .mismatch, operation: .push, category: .reference,
                        message: "Force-with-lease rejected for '\(branch.fullName)': expected remote object \(leaseContext.expectedOID.hex), but the destination advertises \(actual.hex)"
                    )
                case .wrongDestination:
                    throw SwiftGitXError(
                        code: .invalidSpec, operation: .push, category: .reference,
                        message: "Force-with-lease negotiation returned a destination other than '\(branch.fullName)'"
                    )
                }
            }
            try SwiftGitXError.check(status, operation: .push)
        } else {
            try git(operation: .push) {
                git_remote_push(remotePointer, &refspecs, nil)
            }
        }
    }

    // MARK: - Private Helpers

    /// Local path remotes use libgit2's local transport, which lacks an old-OID compare.
    private static func isLocalTransport(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        let value = url.absoluteString
        return !value.contains("://")
    }

    /// Checks if a push refspec is configured for the given branch on the remote.
    ///
    /// - Parameters:
    ///   - branch: The branch to check.
    ///   - remote: The remote to check.
    /// - Returns: `true` if a matching push refspec exists, `false` otherwise.
    /// - Throws: `SwiftGitXError` if the remote lookup fails.
    private func hasPushRefspec(for branch: Branch, remote: Remote) throws(SwiftGitXError) -> Bool {
        let remotePointer = try ReferenceFactory.lookupRemotePointer(name: remote.name, repositoryPointer: pointer)
        defer { git_remote_free(remotePointer) }

        let refspecCount = git_remote_refspec_count(remotePointer)

        for index in 0..<refspecCount {
            guard let refspec = git_remote_get_refspec(remotePointer, index) else { continue }

            let isPushRefspec = git_refspec_direction(refspec) == GIT_DIRECTION_PUSH
            let matchesBranch = git_refspec_src_matches(refspec, branch.fullName) == 1

            if isPushRefspec && matchesBranch {
                return true
            }
        }

        return false
    }

    /// Adds a push refspec for the given branch on the remote.
    ///
    /// - Parameters:
    ///   - branch: The branch to add the refspec for.
    ///   - remote: The remote to add the refspec to.
    private func addPushRefspec(for branch: Branch, remote: Remote) throws(SwiftGitXError) {
        let refspec = "\(branch.fullName):\(branch.fullName)"

        try git(operation: .push) {
            git_remote_add_push(pointer, remote.name, refspec)
        }
    }
}
