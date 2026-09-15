import CloudKit
import Foundation

actor PhotoUploadHistoryCloudSync {
    static let shared = PhotoUploadHistoryCloudSync()

    private static let containerIdentifier = "iCloud.yj.LogSense"
    private static let recordType = "UploadedPhoto"

    private let database: CKDatabase
    private var synchronizationTask: Task<Void, Never>?

    init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        database = container.privateCloudDatabase
    }

    /// Exchanges the complete upload history with the user's private iCloud database.
    /// Calls are coalesced so app activation and an incoming share cannot start duplicate work.
    func synchronize() async {
        if let synchronizationTask {
            await synchronizationTask.value
            return
        }

        let task = Task { [database] in
            do {
                let store = try PhotoUploadHistoryStore.shared()
                let localRecords = store.allRecords()
                let cloudRecords = try await Self.fetchAllRecords(from: database)
                let decodedCloudRecords = cloudRecords.values.compactMap(Self.decode)
                try store.merge(decodedCloudRecords)

                let cloudDates = Dictionary(
                    uniqueKeysWithValues: decodedCloudRecords.map { ($0.contentHash, $0.uploadedAt) }
                )
                for record in localRecords where cloudDates[record.contentHash].map({ $0 < record.uploadedAt }) ?? true {
                    let existing = cloudRecords[record.contentHash]
                    _ = try await database.save(Self.encode(record, updating: existing))
                }
            } catch {
                // iCloud augments local history. Offline and signed-out users can still upload.
                LogSenseLogger.debug("[LogSense] iCloud history sync failed: \(error.localizedDescription)")
            }
        }
        synchronizationTask = task
        await task.value
        synchronizationTask = nil
    }

    func upload(_ record: UploadedPhotoRecord) async {
        do {
            let recordID = CKRecord.ID(recordName: record.contentHash)
            let existing = try? await database.record(for: recordID)
            if let existing,
               let cloudDate = existing["uploadedAt"] as? Date,
               cloudDate >= record.uploadedAt {
                return
            }
            _ = try await database.save(Self.encode(record, updating: existing))
        } catch {
            LogSenseLogger.debug("[LogSense] iCloud history upload failed: \(error.localizedDescription)")
        }
    }

    private static func fetchAllRecords(from database: CKDatabase) async throws -> [String: CKRecord] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var result: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
        do {
            result = try await database.records(matching: query)
        } catch let error as CKError where error.code == .unknownItem {
            // The record type is created lazily by the first save in a new container.
            return [:]
        }
        var records: [String: CKRecord] = [:]

        while true {
            for (_, match) in result.matchResults {
                if case .success(let record) = match {
                    records[record.recordID.recordName] = record
                }
            }
            guard let cursor = result.queryCursor else { break }
            result = try await database.records(continuingMatchFrom: cursor)
        }
        return records
    }

    private static func encode(
        _ value: UploadedPhotoRecord,
        updating existing: CKRecord?
    ) -> CKRecord {
        let record = existing ?? CKRecord(
            recordType: recordType,
            recordID: CKRecord.ID(recordName: value.contentHash)
        )
        record["contentHash"] = value.contentHash as CKRecordValue
        record["byteSize"] = NSNumber(value: value.byteSize)
        record["originalFilename"] = value.originalFilename as CKRecordValue?
        record["gyazoURL"] = value.gyazoURL as CKRecordValue
        record["gyazoImageID"] = value.gyazoImageID as CKRecordValue?
        record["capturedDate"] = value.capturedDate as CKRecordValue
        record["uploadedAt"] = value.uploadedAt as CKRecordValue
        return record
    }

    private static func decode(_ record: CKRecord) -> UploadedPhotoRecord? {
        guard let contentHash = record["contentHash"] as? String,
              contentHash == record.recordID.recordName,
              let byteSize = record["byteSize"] as? NSNumber,
              let gyazoURL = record["gyazoURL"] as? String,
              let capturedDate = record["capturedDate"] as? String,
              let uploadedAt = record["uploadedAt"] as? Date else {
            return nil
        }
        return UploadedPhotoRecord(
            contentHash: contentHash,
            byteSize: byteSize.int64Value,
            originalFilename: record["originalFilename"] as? String,
            gyazoURL: gyazoURL,
            gyazoImageID: record["gyazoImageID"] as? String,
            capturedDate: capturedDate,
            uploadedAt: uploadedAt
        )
    }
}
