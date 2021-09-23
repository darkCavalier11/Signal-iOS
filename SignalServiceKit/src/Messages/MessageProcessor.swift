//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import GRDB
import SignalCoreKit

@objc
public class MessageProcessor: NSObject {
    @objc
    public static let messageProcessorDidFlushQueue = Notification.Name("messageProcessorDidFlushQueue")

    @objc
    public var hasPendingEnvelopes: Bool {
        pendingEnvelopesLock.withLock { !pendingEnvelopes.isEmpty }
    }

    @objc
    @available(swift, obsoleted: 1.0)
    public func processingCompletePromise() -> AnyPromise {
        return AnyPromise(processingCompletePromise())
    }

    public func processingCompletePromise() -> Promise<Void> {
        guard CurrentAppContext().shouldProcessIncomingMessages else {
            if DebugFlags.isMessageProcessingVerbose {
                Logger.verbose("!shouldProcessIncomingMessages")
            }
            return Promise.value(())
        }

        if self.hasPendingEnvelopes {
            if DebugFlags.internalLogging {
                Logger.info("hasPendingEnvelopes, queuedContentCount: \(self.queuedContentCount)")
            }
            return NotificationCenter.default.observe(
                once: Self.messageProcessorDidFlushQueue
            ).then { _ in self.processingCompletePromise() }.asVoid()
        } else if databaseStorage.read(
            block: { Self.groupsV2MessageProcessor.hasPendingJobs(transaction: $0) }
        ) {
            if DebugFlags.internalLogging {
                let pendingJobCount = databaseStorage.read {
                    Self.groupsV2MessageProcessor.pendingJobCount(transaction: $0)
                }
                Logger.verbose("groupsV2MessageProcessor.hasPendingJobs, pendingJobCount: \(pendingJobCount)")
            }
            return NotificationCenter.default.observe(
                once: GroupsV2MessageProcessor.didFlushGroupsV2MessageQueue
            ).then { _ in self.processingCompletePromise() }.asVoid()
        } else {
            if DebugFlags.isMessageProcessingVerbose {
                Logger.verbose("!hasPendingEnvelopes && !hasPendingJobs")
            }
            return Promise.value(())
        }
    }

    @objc
    @available(swift, obsoleted: 1.0)
    public func fetchingAndProcessingCompletePromise() -> AnyPromise {
        return AnyPromise(fetchingAndProcessingCompletePromise())
    }

    public func fetchingAndProcessingCompletePromise() -> Promise<Void> {
        return firstly { () -> Promise<Void> in
            Self.messageFetcherJob.fetchingCompletePromise()
        }.then { () -> Promise<Void> in
            self.processingCompletePromise()
        }
    }

    public override init() {
        super.init()

        SwiftSingletons.register(self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(registrationStateDidChange),
            name: .registrationStateDidChange,
            object: nil
        )

        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            Self.messagePipelineSupervisor.register(pipelineStage: self)

            SDSDatabaseStorage.shared.read { transaction in
                // We may have legacy process jobs queued. We want to schedule them for
                // processing immediately when we launch, so that we can drain the old queue.
                let legacyProcessingJobRecords = AnyMessageContentJobFinder().allJobs(transaction: transaction)
                for jobRecord in legacyProcessingJobRecords {
                    self.processDecryptedEnvelopeData(
                        jobRecord.envelopeData,
                        plaintextData: jobRecord.plaintextData,
                        serverDeliveryTimestamp: jobRecord.serverDeliveryTimestamp,
                        wasReceivedByUD: jobRecord.wasReceivedByUD
                    ) { _ in
                        SDSDatabaseStorage.shared.write { jobRecord.anyRemove(transaction: $0) }
                    }
                }

                // We may have legacy decrypt jobs queued. We want to schedule them for
                // processing immediately when we launch, so that we can drain the old queue.
                let legacyDecryptJobRecords = AnyJobRecordFinder<SSKMessageDecryptJobRecord>().allRecords(
                    label: "SSKMessageDecrypt",
                    status: .ready,
                    transaction: transaction
                )
                for jobRecord in legacyDecryptJobRecords {
                    guard let envelopeData = jobRecord.envelopeData else {
                        owsFailDebug("Skipping job with no envelope data")
                        continue
                    }
                    self.processEncryptedEnvelopeData(envelopeData,
                                                      serverDeliveryTimestamp: jobRecord.serverDeliveryTimestamp,
                                                      envelopeSource: .unknown) { _ in
                        SDSDatabaseStorage.shared.write { jobRecord.anyRemove(transaction: $0) }
                    }
                }
            }
        }
    }

    public struct EnvelopeJob {
        let encryptedEnvelopeData: Data
        let encryptedEnvelope: SSKProtoEnvelope?
        let completion: (Error?) -> Void
    }

    public func processEncryptedEnvelopes(
        envelopeJobs: [EnvelopeJob],
        serverDeliveryTimestamp: UInt64,
        envelopeSource: EnvelopeSource
    ) {
        for envelopeJob in envelopeJobs {
            processEncryptedEnvelopeData(
                envelopeJob.encryptedEnvelopeData,
                encryptedEnvelope: envelopeJob.encryptedEnvelope,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                envelopeSource: envelopeSource,
                completion: envelopeJob.completion
            )
        }
    }

    @objc
    public func processEncryptedEnvelopeData(
        _ encryptedEnvelopeData: Data,
        encryptedEnvelope optionalEncryptedEnvelope: SSKProtoEnvelope? = nil,
        serverDeliveryTimestamp: UInt64,
        envelopeSource: EnvelopeSource,
        completion: @escaping (Error?) -> Void
    ) {
        guard !encryptedEnvelopeData.isEmpty else {
            completion(OWSAssertionError("Empty envelope, envelopeSource: \(envelopeSource)."))
            return
        }

        // Drop any too-large messages on the floor. Well behaving clients should never send them.
        guard encryptedEnvelopeData.count <= Self.maxEnvelopeByteCount else {
            completion(OWSAssertionError("Oversize envelope, envelopeSource: \(envelopeSource)."))
            return
        }

        // Take note of any messages larger than we expect, but still process them.
        // This likely indicates a misbehaving sending client.
        if encryptedEnvelopeData.count > Self.largeEnvelopeWarningByteCount {
            Logger.verbose("encryptedEnvelopeData: \(encryptedEnvelopeData.count) > : \(Self.largeEnvelopeWarningByteCount)")
            owsFailDebug("Unexpectedly large envelope, envelopeSource: \(envelopeSource).")
        }

        let encryptedEnvelope: SSKProtoEnvelope
        if let optionalEncryptedEnvelope = optionalEncryptedEnvelope {
            encryptedEnvelope = optionalEncryptedEnvelope
        } else {
            do {
                encryptedEnvelope = try SSKProtoEnvelope(serializedData: encryptedEnvelopeData)
            } catch {
                owsFailDebug("Failed to parse encrypted envelope \(error), envelopeSource: \(envelopeSource)")
                completion(error)
                return
            }
        }

        pendingEnvelopesLock.withLock {
            pendingEnvelopes.append(EncryptedEnvelope(
                encryptedEnvelopeData: encryptedEnvelopeData,
                encryptedEnvelope: encryptedEnvelope,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                completion: completion
            ))
        }

        drainPendingEnvelopes()
    }

    @objc
    public func processDecryptedEnvelopeData(
        _ envelopeData: Data,
        plaintextData: Data?,
        serverDeliveryTimestamp: UInt64,
        wasReceivedByUD: Bool,
        completion: @escaping (Error?) -> Void
    ) {
        pendingEnvelopesLock.withLock {
            let oldCount = pendingEnvelopes.count
            pendingEnvelopes.append(DecryptedEnvelope(
                envelopeData: envelopeData,
                plaintextData: plaintextData,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                wasReceivedByUD: wasReceivedByUD,
                completion: completion
            ))
            let newCount = pendingEnvelopes.count
            if DebugFlags.internalLogging {
                Logger.info("\(oldCount) -> \(newCount)")
            }
        }

        drainPendingEnvelopes()
    }

    // The NSE has tight memory constraints.
    // For perf reasons, MessageProcessor keeps its queue in memory.
    // It is not safe for the NSE to fetch more messages
    // and cause this queue to grow in an unbounded way.
    // Therefore, the NSE should wait to fetch more messages if
    // the queue has "some/enough" content.
    // However, the NSE needs to process messages with high
    // throughput.
    // Therfore we need to identify a constant N small enough to
    // place an acceptable upper bound on memory usage of the processor
    // (N + next fetched batch size, fetch size in practice is 100),
    // large enough to avoid introducing latency (e.g. the next fetch
    // will complete before the queue is empty).
    // This is tricky since there are multiple variables (e.g. network
    // perf affects fetch, CPU perf affects processing).
    public var hasSomeQueuedContent: Bool {
        queuedContentCount >= 25
    }

    public var queuedContentCount: Int {
        pendingEnvelopesLock.withLock {
            pendingEnvelopes.count
        }
    }

    private static let maxEnvelopeByteCount = 250 * 1024
    public static let largeEnvelopeWarningByteCount = 25 * 1024
    private let serialQueue = DispatchQueue(label: "MessageProcessor.processingQueue",
                                            autoreleaseFrequency: .workItem)

    private let pendingEnvelopesLock = UnfairLock()
    private var pendingEnvelopes = [PendingEnvelope]()
    private var isDrainingPendingEnvelopes = false {
        didSet { assertOnQueue(serialQueue) }
    }

    private func drainPendingEnvelopes() {
        guard Self.messagePipelineSupervisor.isMessageProcessingPermitted else { return }
        guard TSAccountManager.shared.isRegisteredAndReady else { return }

        guard CurrentAppContext().shouldProcessIncomingMessages else { return }

        serialQueue.async {
            guard !self.isDrainingPendingEnvelopes else { return }
            self.isDrainingPendingEnvelopes = true
            self.drainNextBatch()
        }
    }

    private func drainNextBatch() {
        assertOnQueue(serialQueue)

        let shouldContinue: Bool = autoreleasepool {
            // We want a value that is just high enough to yield perf benefits.
            let kIncomingMessageBatchSize = 16
            // If the app is in the background, use batch size of 1.
            // This reduces the risk of us never being able to drain any
            // messages from the queue. We should fine tune this number
            // to yield the best perf we can get.
            let batchSize = CurrentAppContext().isInBackground() ? 1 : kIncomingMessageBatchSize
            var batchEnvelopes = [PendingEnvelope]()
            var pendingEnvelopesCount: Int = 0
            pendingEnvelopesLock.withLock {
                batchEnvelopes = Array(pendingEnvelopes.prefix(batchSize))
                pendingEnvelopesCount = pendingEnvelopes.count
            }

            guard !batchEnvelopes.isEmpty else {
                isDrainingPendingEnvelopes = false
                if DebugFlags.internalLogging {
                    Logger.info("Processing complete: \(self.queuedContentCount).")
                }
                NotificationCenter.default.postNotificationNameAsync(Self.messageProcessorDidFlushQueue, object: nil)
                return false
            }

            Logger.info("Processing batch of \(batchEnvelopes.count)/\(pendingEnvelopesCount) received envelope(s).")

            SDSDatabaseStorage.shared.write { transaction in
                batchEnvelopes.forEach { self.processEnvelope($0, transaction: transaction) }
            }

            // Remove the processed envelopes from the pending list.
            pendingEnvelopesLock.withLock {
                guard pendingEnvelopes.count > batchEnvelopes.count else {
                    pendingEnvelopes = []
                    return
                }
                let oldCount = pendingEnvelopes.count
                pendingEnvelopes = Array(pendingEnvelopes.suffix(from: batchEnvelopes.count))
                let newCount = pendingEnvelopes.count
                if DebugFlags.internalLogging {
                    Logger.info("\(oldCount) -> \(newCount)")
                }
            }

            return true
        }

        if shouldContinue {
            self.drainNextBatch()
        }
    }

    private func processEnvelope(_ pendingEnvelope: PendingEnvelope, transaction: SDSAnyWriteTransaction) {
        assertOnQueue(serialQueue)

        switch pendingEnvelope.decrypt(transaction: transaction) {
        case .success(let result):
            let envelope: SSKProtoEnvelope
            do {
                // NOTE: We use envelopeData from the decrypt result, not the pending envelope,
                // since the envelope may be altered by the decryption process in the UD case.
                envelope = try SSKProtoEnvelope(serializedData: result.envelopeData)
            } catch {
                owsFailDebug("Failed to parse decrypted envelope \(error)")
                transaction.addAsyncCompletionOffMain { pendingEnvelope.completion(error) }
                return
            }

            // Pre-processing happens during the same transaction that performed decryption
            messageManager.preprocessEnvelope(envelope: envelope, plaintext: result.plaintextData, transaction: transaction)

            // If the sender is in the block list, we can skip scheduling any additional processing.
            if let sourceAddress = envelope.sourceAddress, blockingManager.isAddressBlocked(sourceAddress) {
                Logger.info("Skipping processing for blocked envelope: \(sourceAddress)")

                let error = OWSGenericError("Ignoring blocked envelope: \(sourceAddress)")
                transaction.addAsyncCompletionOffMain { pendingEnvelope.completion(error) }
                return
            }

            enum ProcessingStep {
                case discard
                case enqueueForGroupProcessing
                case processNow(shouldDiscardVisibleMessages: Bool)
            }
            let processingStep = { () -> ProcessingStep in
                guard let groupContextV2 = GroupsV2MessageProcessor.groupContextV2(
                    forEnvelope: envelope,
                    plaintextData: result.plaintextData
                ) else {
                    // Non-v2-group messages can be processed immediately.
                    return .processNow(shouldDiscardVisibleMessages: false)
                }

                guard GroupsV2MessageProcessor.canContextBeProcessedImmediately(
                    groupContext: groupContextV2,
                    transaction: transaction
                ) else {
                    // Some v2 group messages required group state to be
                    // updated before they can be processed.
                    return .enqueueForGroupProcessing
                }
                let discardMode = GroupsMessageProcessor.discardMode(
                    envelopeData: result.envelopeData,
                    plaintextData: result.plaintextData,
                    groupContext: groupContextV2,
                    wasReceivedByUD: result.wasReceivedByUD,
                    serverDeliveryTimestamp: result.serverDeliveryTimestamp,
                    transaction: transaction
                )
                if discardMode == .discard {
                    // Some v2 group messages should be discarded and not processed.
                    Logger.verbose("Discarding job.")
                    return .discard
                }
                // Some v2 group messages should be processed, but
                // discarding any "visible" messages, e.g. text messages
                // or calls.
                return .processNow(shouldDiscardVisibleMessages: discardMode == .discardVisibleMessages)
            }()

            switch processingStep {
            case .discard:
                // Do nothing.
                Logger.verbose("Discarding job.")
            case .enqueueForGroupProcessing:
                // If we can't process the message immediately, we enqueue it for
                // for processing in the same transaction within which it was decrypted
                // to prevent data loss.
                Self.groupsV2MessageProcessor.enqueue(
                    envelopeData: result.envelopeData,
                    plaintextData: result.plaintextData,
                    envelope: envelope,
                    wasReceivedByUD: result.wasReceivedByUD,
                    serverDeliveryTimestamp: result.serverDeliveryTimestamp,
                    transaction: transaction
                )
            case .processNow(let shouldDiscardVisibleMessages):
                // Envelopes can be processed immediately if they're:
                // 1. Not a GV2 message.
                // 2. A GV2 message that doesn't require updating the group.
                //
                // The advantage to processing the message immediately is that
                // we can full process the message in the same transaction that
                // we used to decrypt it. This results in a significant perf
                // benefit verse queueing the message and waiting for that queue
                // to open new transactions and process messages. The downside is
                // that if we *fail* to process this message (e.g. the app crashed
                // or was killed), we'll have to re-decrypt again before we process.
                // This is safe, since the decrypt operation would also be rolled
                // back (since the transaction didn't finalize) and should be rare.
                Self.messageManager.processEnvelope(
                    envelope,
                    plaintextData: result.plaintextData,
                    wasReceivedByUD: result.wasReceivedByUD,
                    serverDeliveryTimestamp: result.serverDeliveryTimestamp,
                    shouldDiscardVisibleMessages: shouldDiscardVisibleMessages,
                    transaction: transaction
                )
            }

            transaction.addAsyncCompletionOffMain { pendingEnvelope.completion(nil) }
        case .failure(let error):
            transaction.addAsyncCompletionOffMain {
                pendingEnvelope.completion(error)
            }
        }
    }

    @objc
    func registrationStateDidChange() {
        AppReadiness.runNowOrWhenAppDidBecomeReadySync {
            self.drainPendingEnvelopes()
        }
    }
}

// MARK: -

extension MessageProcessor: MessageProcessingPipelineStage {
    public func supervisorDidResumeMessageProcessing(_ supervisor: MessagePipelineSupervisor) {
        drainPendingEnvelopes()
    }
}

// MARK: -

private protocol PendingEnvelope {
    var completion: (Error?) -> Void { get }
    var wasReceivedByUD: Bool { get }
    func decrypt(transaction: SDSAnyWriteTransaction) -> Swift.Result<DecryptedEnvelope, Error>
}

// MARK: -

class MessageDecryptDeduplicationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "MessageDecryptDeduplication"

    var id: Int64?
    let serviceTimestamp: UInt64
    let serverGuid: String

    init(serviceTimestamp: UInt64, serverGuid: String) {
        self.serviceTimestamp = serviceTimestamp
        self.serverGuid = serverGuid
    }

    func didInsert(with rowID: Int64, for column: String?) {
        guard column == "id" else { return owsFailDebug("Expected id") }
        id = rowID
    }

    public enum Outcome {
        case nonDuplicate
        case duplicate
    }

    public static func deduplicate(
        encryptedEnvelope: SSKProtoEnvelope,
        transaction: SDSAnyWriteTransaction,
        skipCull: Bool = false
    ) -> Outcome {
        deduplicate(serviceTimestamp: encryptedEnvelope.serverTimestamp,
                    serverGuid: encryptedEnvelope.serverGuid,
                    transaction: transaction,
                    skipCull: skipCull)
    }

    public static func deduplicate(
        serviceTimestamp: UInt64,
        serverGuid: String?,
        transaction: SDSAnyWriteTransaction,
        skipCull: Bool = false
    ) -> Outcome {
        guard serviceTimestamp > 0 else {
            owsFailDebug("Missing serviceTimestamp.")
            return .nonDuplicate
        }
        guard let serverGuid = serverGuid?.nilIfEmpty else {
            owsFailDebug("Missing serverGuid.")
            return .nonDuplicate
        }
        do {
            let records = try MessageDecryptDeduplicationRecord
                .filter(Column("serviceTimestamp") == serviceTimestamp)
                .filter(Column("serverGuid") == serverGuid)
                .fetchAll(transaction.unwrapGrdbRead.database)
            guard records.isEmpty else {
                Logger.warn("Discarding duplicate envelope with serviceTimestamp: \(serviceTimestamp), serverGuid: \(serverGuid)")
                return .duplicate
            }

            // No existing record found. Create a new one and insert it.
            let record = MessageDecryptDeduplicationRecord(serviceTimestamp: serviceTimestamp,
                                                           serverGuid: serverGuid)
            try record.insert(transaction.unwrapGrdbWrite.database)

            if !skipCull, shouldCull() {
                cull(latestServiceTimestamp: serviceTimestamp, transaction: transaction)
            }

            return .nonDuplicate
        } catch {
            owsFailDebug("Error: \(error)")
            // If anything goes wrong with our bookkeeping, we must
            // proceed with message processing.
            return .nonDuplicate
        }
    }

    static let maxRecordCount: UInt = 1000
    static let maxRecordAgeMs: UInt64 = 5 * kMinuteInMs

    private static func cull(latestServiceTimestamp: UInt64,
                             transaction: SDSAnyWriteTransaction) {
        let count1 = recordCount(transaction: transaction)

        // Client and service time might not match; use service timestamps for
        // all record bookkeeping.
        let recordExpirationTimestamp = latestServiceTimestamp - maxRecordAgeMs
        let sql = """
            DELETE FROM MessageDecryptDeduplication
            WHERE serviceTimestamp < ?;
        """
        transaction.unwrapGrdbWrite.executeUpdate(sql: sql, arguments: [recordExpirationTimestamp])

        let count2 = recordCount(transaction: transaction)
        if count1 != count2 {
            Logger.info("Culled by timestamp: \(count1) -> \(count2)")
        }

        guard count2 > maxRecordCount else {
            return
        }

        do {
            // It is sufficient to cull by record count in batches.
            // The batch size must be larger than our cull frequency to bound total record count.
            let cullCount: Int = min(Int(cullFrequency) * 2, Int(count2) - Int(maxRecordCount))

            Logger.info("Culling \(cullCount) records.")

            // Find and delete the oldest N records.
            let records = try MessageDecryptDeduplicationRecord.order(GRDB.Column("serviceTimestamp"))
                .limit(cullCount)
                .fetchAll(transaction.unwrapGrdbRead.database)
            for record in records {
                try record.delete(transaction.unwrapGrdbWrite.database)
            }

            let count3 = recordCount(transaction: transaction)
            if count2 != count3 {
                Logger.info("Culled by count: \(count2) -> \(count3)")
            }
            owsAssertDebug(count3 <= maxRecordCount)
        } catch {
            owsFailDebug("Error: \(error)")
        }
    }

    public static func recordCount(transaction: SDSAnyReadTransaction) -> UInt {
        MessageDecryptDeduplicationRecord.ows_fetchCount(transaction.unwrapGrdbRead.database)
    }

    private static let unfairLock = UnfairLock()
    private static var counter: UInt64 = 0
    static let cullFrequency: UInt64 = 100

    private static func shouldCull() -> Bool {
        unfairLock.withLock {
            // Cull records once per N decryptions.
            //
            // NOTE: this always return true the first time that this
            // method is called for a given launch of the process.
            // We need to err on the side of culling too often to bound
            // total record count.
            let shouldCull = counter % cullFrequency == 0
            counter += 1
            return shouldCull
        }
    }
}

// MARK: -

private struct EncryptedEnvelope: PendingEnvelope, Dependencies {
    let encryptedEnvelopeData: Data
    let encryptedEnvelope: SSKProtoEnvelope
    let serverDeliveryTimestamp: UInt64
    let completion: (Error?) -> Void

    var wasReceivedByUD: Bool {
        let hasSenderSource: Bool
        if encryptedEnvelope.hasValidSource {
            hasSenderSource = true
        } else {
            hasSenderSource = false
        }
        return encryptedEnvelope.type == .unidentifiedSender && !hasSenderSource
    }

    func decrypt(transaction: SDSAnyWriteTransaction) -> Swift.Result<DecryptedEnvelope, Error> {
        let deduplicationOutcome = MessageDecryptDeduplicationRecord.deduplicate(encryptedEnvelope: encryptedEnvelope,
                                                                                 transaction: transaction)
        switch deduplicationOutcome {
        case .nonDuplicate:
            // Proceed with decryption.
            break
        case .duplicate:
            return .failure(OWSGenericError("Ignoring duplicate envelope with timestamp: \(serverDeliveryTimestamp)."))
        }

        let result = Self.messageDecrypter.decryptEnvelope(
            encryptedEnvelope,
            envelopeData: encryptedEnvelopeData,
            transaction: transaction
        )
        switch result {
        case .success(let result):
            return .success(DecryptedEnvelope(
                envelopeData: result.envelopeData,
                plaintextData: result.plaintextData,
                serverDeliveryTimestamp: serverDeliveryTimestamp,
                wasReceivedByUD: wasReceivedByUD,
                completion: completion
            ))
        case .failure(let error):
            return .failure(error)
        }
    }
}

// MARK: -

private struct DecryptedEnvelope: PendingEnvelope {
    let envelopeData: Data
    let plaintextData: Data?
    let serverDeliveryTimestamp: UInt64
    let wasReceivedByUD: Bool
    let completion: (Error?) -> Void

    func decrypt(transaction: SDSAnyWriteTransaction) -> Swift.Result<DecryptedEnvelope, Error> {
        return .success(self)
    }
}

// MARK: -

@objc
public enum EnvelopeSource: UInt, CustomStringConvertible {
    case unknown
    case websocketIdentified
    case websocketUnidentified
    case rest
    // We re-decrypt incoming messages after accepting a safety number change.
    case identityChangeError
    case debugUI
    case tests

    // MARK: - CustomStringConvertible

    public var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .websocketIdentified:
            return "websocketIdentified"
        case .websocketUnidentified:
            return "websocketUnidentified"
        case .rest:
            return "rest"
        case .identityChangeError:
            return "identityChangeError"
        case .debugUI:
            return "debugUI"
        case .tests:
            return "tests"
        }
    }
}
