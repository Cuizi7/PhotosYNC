// Inserted only into disposable copies by run-reconciliation-request-races.py.
// The runtime support is never compiled into a shipping app.
// RUNTIME SUPPORT
actor ReconciliationRaceGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var blocked: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true; entry?.resume(); entry = nil
        await withCheckedContinuation { blocked = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entry = $0 } }
    }
    func release() { blocked?.resume(); blocked = nil }
}
// TEST SUPPORT
extension AdvancedRuntimeTests {
    func testCoverageReplyPreservesNewFullContextForceAndPermissionRequests() async throws {
        for action in ["full", "context", "force", "permission"] {
            let f = try await fixture(), admission = P8Gate(), reply = ReconciliationRaceGate()
            await f.runtime.tick(force: true); await f.runtime.waitForRound()
            let before = await f.photos.catalogCount
            await f.photos.gateNextAdmission(admission)
            await f.runtime.tick(); await admission.waitUntilEntered()
            await f.photos.advanceGeneration(); await f.runtime.libraryChanged(.fullReconcileRequired)
            await f.runtime.holdCoverageReply(using: reply)
            await admission.release(); await reply.waitUntilEntered()
            // Retain the owned task before releasing its gate. waitForRound alone
            // can see no registered handles during the old tail's await tick.
            let ownedWork = await f.runtime.capturedAdvancedWorkForRace()
            XCTAssertNotNil(ownedWork)
            // If old confirmation loses the new request, due-work cannot mask it
            // with an internal full pass while the physical reader is unavailable.
            await f.photos.setAdmission(.draining)
            switch action {
            case "full": await f.runtime.libraryChanged(.fullReconcileRequired)
            case "context": await f.runtime.libraryChanged(.contextInvalidated)
            case "force": await f.runtime.tick(force: true)
            default:
                f.authorization.value = false; await f.runtime.tick()
                f.authorization.value = true; await f.runtime.tick()
            }
            await reply.release(); await ownedWork?.value; await f.runtime.waitForRound()
            let after = await f.photos.catalogCount
            XCTAssertEqual(after - before, 2, "coverage_reply_preserves_new_\(action)")
        }
    }

    func testDelayedCoveredReceiptDoesNotRequestAnotherCatalog() async throws {
        let f = try await fixture(), admission = P8Gate(), receipt = ReconciliationRaceGate()
        await f.runtime.tick(force: true); await f.runtime.waitForRound()
        let before = await f.photos.catalogCount
        await f.photos.gateNextAdmission(admission)
        await f.runtime.tick(); await admission.waitUntilEntered()
        await f.runtime.holdEventReceipt(using: receipt)
        await f.photos.advanceGeneration()
        let event = Task { await f.runtime.libraryChanged(.fullReconcileRequired) }
        await receipt.waitUntilEntered()
        await admission.release(); await f.runtime.waitForRound()
        // The coordinator covered the event while its runtime handler still
        // awaited the reply, so work-end confirmation had no receipt to consume.
        await receipt.release(); await event.value; await f.runtime.waitForRound()
        let after = await f.photos.catalogCount
        XCTAssertEqual(after - before, 1, "delayed_covered_receipt")
    }
}
