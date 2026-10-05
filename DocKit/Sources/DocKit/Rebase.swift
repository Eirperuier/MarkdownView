/// The OT transform grid a client rebase needs: given the local `pending`
/// sequence and a `remote` sequence the server ordered first, produce both
/// sequences re-expressed against each other. `remote ++ local'` and
/// `local ++ remote'` describe the same doc.
///
/// Mapping through step *inverses* (the naive rebase) forgets where text
/// came from — a delete of text a sibling insert created collapses. The
/// pairwise transform keeps it: every cell of the grid crosses the current
/// version of one local step with the current version of one remote step,
/// remote winning position ties because it is ordered first.
extension DocStep {
    /// `local` re-expressed after `remote`, and `remote` re-expressed after
    /// `local`; remote wins ties (it is server-ordered first).
    public static func transform(_ local: [DocStep], over remote: [DocStep]) -> (local: [DocStep], remote: [DocStep]) {
        let grouped = transformGrouped(local, over: remote)
        return (grouped.local.flatMap { $0 }, grouped.remote)
    }

    /// The same transform, keeping the steps each original local step
    /// turned into grouped together — rebase reports drops per original.
    static func transformGrouped(_ local: [DocStep], over remote: [DocStep]) -> (local: [[DocStep]], remote: [DocStep]) {
        var localVersions = local.map { [$0] }
        var remoteVersions = remote.map { [$0] }
        for remoteIndex in remoteVersions.indices {
            for localIndex in localVersions.indices {
                let cell = transformCell(localVersions[localIndex], remoteVersions[remoteIndex])
                localVersions[localIndex] = cell.local
                remoteVersions[remoteIndex] = cell.remote
            }
        }
        return (localVersions, remoteVersions.flatMap { $0 })
    }

    /// One grid cell. A step that split in two (a range straddling a split)
    /// is a sequence, and two sequences transform by a grid of their own —
    /// mapping through each piece separately would duplicate the step.
    private static func transformCell(_ local: [DocStep], _ remote: [DocStep]) -> (local: [DocStep], remote: [DocStep]) {
        guard local.count == 1, remote.count == 1 else {
            let grouped = transformGrouped(local, over: remote)
            return (grouped.local.flatMap { $0 }, grouped.remote)
        }
        return (
            local[0].mapped(through: remote[0], otherFirst: true),
            remote[0].mapped(through: local[0], otherFirst: false)
        )
    }
}
