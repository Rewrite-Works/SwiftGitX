/// Controls how a branch push handles non-fast-forward updates.
public enum PushStrategy: Sendable {
    /// Accept only fast-forward updates, which is the default Git behavior.
    case normal

    /// Allow the destination branch to move to any commit.
    case force

    /// Allow a forced update only when the destination still has `expectedOID`.
    ///
    /// The expected ID must be captured before rewriting local history. This strategy
    /// requires an existing destination branch and a smart Git transport whose server
    /// enforces the advertised old object ID during the reference update.
    case forceWithLease(expectedOID: OID)
}
