//
//  CTDTests.swift
//  CTDTests
//
//  Created by Yuki Jin on 2024/08/25.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import CTD

final class CTDTests: XCTestCase {
    func testPhotoImportWaitsForActiveSceneBeforeStartingSharedBatch() {
        XCTAssertEqual(
            PhotoImportScenePolicy.action(for: .inactive, hasPendingImport: true),
            .wait
        )
        XCTAssertEqual(
            PhotoImportScenePolicy.action(for: .background, hasPendingImport: true),
            .wait
        )
        XCTAssertEqual(
            PhotoImportScenePolicy.action(for: .active, hasPendingImport: true),
            .startPendingImport
        )
    }

    func testPhotoImportStillPausesWhenAppLeavesForegroundWithoutSharedBatch() {
        XCTAssertEqual(
            PhotoImportScenePolicy.action(for: .background, hasPendingImport: false),
            .pauseCurrentImport
        )
        XCTAssertEqual(
            PhotoImportScenePolicy.action(for: .inactive, hasPendingImport: false),
            .wait
        )
    }

    func testPhotoImportAutomaticallyStartsOnlyFreshOrInterruptedUploads() {
        XCTAssertTrue(PhotoImportScenePolicy.canStartAutomatically(.staging))
        XCTAssertTrue(PhotoImportScenePolicy.canStartAutomatically(.staged))
        XCTAssertTrue(PhotoImportScenePolicy.canStartAutomatically(.uploading))
        XCTAssertFalse(PhotoImportScenePolicy.canStartAutomatically(.paused))
        XCTAssertFalse(PhotoImportScenePolicy.canStartAutomatically(.awaitingDecision))
        XCTAssertFalse(PhotoImportScenePolicy.canStartAutomatically(.commitUncertain))
        XCTAssertFalse(PhotoImportScenePolicy.canStartAutomatically(.completed))
    }

    @MainActor
    func testPhotoImportCoordinatorIgnoresDuplicateStartForActiveBatch() {
        let batchID = UUID()

        XCTAssertEqual(
            PhotoImportCoordinator.startDecision(
                isWorking: true,
                currentBatchID: batchID,
                requestedBatchID: batchID
            ),
            .ignoreCurrentBatch
        )
    }

    @MainActor
    func testPhotoImportCoordinatorRejectsDifferentBatchWhileWorking() {
        XCTAssertEqual(
            PhotoImportCoordinator.startDecision(
                isWorking: true,
                currentBatchID: UUID(),
                requestedBatchID: UUID()
            ),
            .rejectDifferentBatch
        )
    }

    @MainActor
    func testPhotoImportCoordinatorAllowsStartWhileIdle() {
        XCTAssertEqual(
            PhotoImportCoordinator.startDecision(
                isWorking: false,
                currentBatchID: UUID(),
                requestedBatchID: UUID()
            ),
            .start
        )
    }

    func testScrapboxURLBuilderPreservesBodyAsSingleQueryValue() throws {
        let body = "[Example & Notes https://example.com/page?a=1&b=2]\n#inbox"
        let url = try XCTUnwrap(
            ScrapboxURLBuilder.makePageURL(
                project: "demo/project",
                title: "Example & Notes",
                body: body
            )
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/demo/project/Example & Notes")
        XCTAssertEqual(components.percentEncodedPath, "/demo%2Fproject/Example%20%26%20Notes")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "body", value: body)])
        XCTAssertNil(components.fragment)
    }

    func testContentURLAllowsOnlyHTTPSOnScrapboxDomain() {
        XCTAssertTrue(WebURLPolicy.isAllowedContentURL(URL(string: "https://scrapbox.io/project/page")!))
        XCTAssertTrue(WebURLPolicy.isAllowedContentURL(URL(string: "https://sub.scrapbox.io/project/page")!))
        XCTAssertFalse(WebURLPolicy.isAllowedContentURL(URL(string: "http://scrapbox.io/project/page")!))
        XCTAssertFalse(WebURLPolicy.isAllowedContentURL(URL(string: "https://scrapbox.io.evil.example/page")!))
        XCTAssertFalse(WebURLPolicy.isAllowedContentURL(URL(string: "javascript:alert(1)")!))
    }

    func testGoogleDomainIsAllowedOnlyForInAppAuthentication() {
        let googleURL = URL(string: "https://accounts.google.com/signin")!

        XCTAssertTrue(WebURLPolicy.isAllowedInAppURL(googleURL))
        XCTAssertFalse(WebURLPolicy.isAllowedContentURL(googleURL))
        XCTAssertFalse(WebURLPolicy.isAllowedInAppURL(URL(string: "https://accounts.google.com.evil.example")!))
    }

    func testImageMetadataReaderExtractsExifDateAndCameraInformation() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let data = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                data,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        )
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:08:25 12:34:56",
                kCGImagePropertyExifLensModel: "Test Lens 35mm"
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFModel: "Test Camera"
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let metadata = ImageMetadataReader.read(from: data as Data)

        XCTAssertEqual(metadata.date, "2024-08-25")
        XCTAssertEqual(metadata.cameraModel, "Test Camera")
        XCTAssertEqual(metadata.lensModel, "Test Lens 35mm")
    }

    func testImageMetadataReaderRejectsInvalidExifDate() {
        XCTAssertNil(ImageMetadataReader.normalizedDate("not-a-date"))
        XCTAssertNil(ImageMetadataReader.normalizedDate(nil))
    }

    func testImageMetadataReaderReadsFromFileWithoutLoadingDataFirst() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseMetadata-\(UUID().uuidString).jpg")
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(ImageMetadataReader.read(from: url), ImageMetadata(date: nil, cameraModel: nil, lensModel: nil))
    }

    @MainActor
    func testWebViewModelCreatesWebViewOnlyWhenDisplayed() {
        let model = WebViewModel(url: URL(string: "about:blank")!)

        XCTAssertFalse(model.isWebViewCreated)
        model.loadURL(URL(string: "about:blank")!)
        XCTAssertFalse(model.isWebViewCreated)

        _ = model.webViewForDisplay()
        XCTAssertTrue(model.isWebViewCreated)
    }

    @MainActor
    func testWebViewModelLoadsEveryPageAppendSequentially() async throws {
        let model = WebViewModel(url: URL(string: "about:blank?initial")!)
        let urls = [
            URL(string: "about:blank?date=2026-06-14")!,
            URL(string: "about:blank?date=2026-06-01")!
        ]

        let succeeded = await withCheckedContinuation { continuation in
            model.loadURLsSequentially(urls) { success in
                continuation.resume(returning: success)
            }
        }

        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.currentURL, urls.last)
    }

    @MainActor
    func testPageTextVerificationWaitsForAsyncFetchResult() async throws {
        let webView = CustomWebView()
        let loaded = await withCheckedContinuation { continuation in
            webView.loadURL(URL(string: "about:blank")!) { success in
                continuation.resume(returning: success)
            }
        }
        XCTAssertTrue(loaded)

        let result = await withCheckedContinuation { continuation in
            webView.checkPageText(
                at: URL(string: "data:text/plain,async-verification-complete")!,
                containing: ["async-verification-complete"]
            ) { result in
                continuation.resume(returning: result)
            }
        }

        XCTAssertEqual(result, .confirmed)
    }

    @MainActor
    func testInputAccessoryViewIsReused() {
        let webView = CustomWebView()

        XCTAssertTrue(webView.inputAccessoryView === webView.inputAccessoryView)
    }

    func testPhotoImportBodyBuilderGroupsByDateAndPreservesSelectionOrder() {
        let items = [
            makeUploadedPhoto(index: 2, date: "2026-07-21", url: "https://i.gyazo.com/3.jpg"),
            makeUploadedPhoto(index: 0, date: "2026-07-20", url: "https://i.gyazo.com/1.jpg"),
            makeUploadedPhoto(index: 1, date: "2026-07-20", url: "https://i.gyazo.com/2.jpg")
        ]

        let appends = PhotoImportBodyBuilder.makeAppends(from: items)

        XCTAssertEqual(appends.map(\.pageTitle), ["2026-07-20", "2026-07-21"])
        XCTAssertEqual(
            appends.map(\.verificationFragments),
            [
                ["https://i.gyazo.com/1.jpg", "https://i.gyazo.com/2.jpg"],
                ["https://i.gyazo.com/3.jpg"]
            ]
        )
        XCTAssertTrue(appends[0].body.contains("[https://i.gyazo.com/1.jpg]"))
        XCTAssertTrue(appends[0].body.contains("[https://i.gyazo.com/2.jpg]"))
        XCTAssertLessThan(
            try XCTUnwrap(appends[0].body.range(of: "1.jpg")?.lowerBound),
            try XCTUnwrap(appends[0].body.range(of: "2.jpg")?.lowerBound)
        )
    }

    func testPageAppendRequestsKeepEveryDateAndVerificationTarget() throws {
        let items = [
            makeUploadedPhoto(index: 0, date: "2026-06-14", url: "https://i.gyazo.com/june14.jpg"),
            makeUploadedPhoto(index: 1, date: "2026-06-01", url: "https://i.gyazo.com/june01.jpg")
        ]
        let appends = PhotoImportBodyBuilder.makeAppends(from: items)

        let requests = try appends.map {
            try XCTUnwrap(
                ScrapboxURLBuilder.makePageAppendRequest(project: "private-jindazs", append: $0)
            )
        }

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests.map(\.contextURL.path),
            ["/private-jindazs", "/private-jindazs"]
        )
        XCTAssertEqual(
            requests.map(\.pageURL.path),
            ["/private-jindazs/2026-06-14", "/private-jindazs/2026-06-01"]
        )
        XCTAssertEqual(
            requests.map(\.verificationURL.path),
            [
                "/api/pages/private-jindazs/2026-06-14/text",
                "/api/pages/private-jindazs/2026-06-01/text"
            ]
        )
        XCTAssertEqual(
            requests.map(\.expectedFragments),
            [["https://i.gyazo.com/june14.jpg"], ["https://i.gyazo.com/june01.jpg"]]
        )
    }

    func testSafePageAppendRetrySkipsConfirmedAndStopsWhenVerificationIsUnavailable() {
        XCTAssertEqual(PageAppendRetryPolicy.action(for: .confirmed), .skip)
        XCTAssertEqual(PageAppendRetryPolicy.action(for: .missing), .append)
        XCTAssertEqual(PageAppendRetryPolicy.action(for: .unavailable), .stop)
    }

    func testPageVerificationWaitsForCosenseWebContextToFinishLoading() {
        let cosenseURL = URL(string: "https://scrapbox.io/jindazs")!
        let apiURL = URL(string: "https://scrapbox.io/api/pages/jindazs/2026-06-14/text")!

        XCTAssertTrue(PageVerificationContextPolicy.requiresBootstrap(
            currentURL: nil,
            isLoading: false,
            targetURL: apiURL
        ))
        XCTAssertTrue(PageVerificationContextPolicy.requiresBootstrap(
            currentURL: cosenseURL,
            isLoading: true,
            targetURL: apiURL
        ))
        XCTAssertTrue(PageVerificationContextPolicy.requiresBootstrap(
            currentURL: URL(string: "about:blank"),
            isLoading: false,
            targetURL: apiURL
        ))
        XCTAssertFalse(PageVerificationContextPolicy.requiresBootstrap(
            currentURL: cosenseURL,
            isLoading: false,
            targetURL: apiURL
        ))
    }

    func testPhotoImportBodyBuilderChunksLargeSameDayBatch() {
        let items = (0..<5).map {
            makeUploadedPhoto(
                index: $0,
                date: "2026-07-20",
                url: "https://i.gyazo.com/\($0).jpg"
            )
        }

        let appends = PhotoImportBodyBuilder.makeAppends(
            from: items,
            maximumImagesPerAppend: 2
        )

        XCTAssertEqual(appends.count, 3)
        XCTAssertEqual(appends.map(\.itemIDs.count), [2, 2, 1])
    }

    func testPhotoImportBodyBuilderExcludesSkippedDuplicates() {
        let uploaded = makeUploadedPhoto(index: 0, date: "2026-07-20", url: "https://i.gyazo.com/1.jpg")
        var skipped = makeStagedPhoto(index: 1)
        skipped.state = .skipped
        let batch = PhotoImportBatch(
            id: UUID(),
            destination: .photo,
            projectName: "photos",
            createdAt: Date(),
            items: [uploaded, skipped],
            state: .completed
        )

        let appends = PhotoImportBodyBuilder.makeAppends(from: batch.items)

        XCTAssertEqual(appends.count, 1)
        XCTAssertEqual(appends[0].itemIDs, [uploaded.id])
        XCTAssertEqual(batch.skippedCount, 1)
        XCTAssertEqual(batch.processedCount, 2)
        XCTAssertEqual(batch.completionMessage, "1枚を追加し、1枚の重複をスキップしました。")
    }

    func testImageFingerprintDetectsExactDuplicates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("first.heic")
        let renamedCopy = directory.appendingPathComponent("renamed.heic")
        let different = directory.appendingPathComponent("different.heic")
        try Data("same-image-data".utf8).write(to: first)
        try Data("same-image-data".utf8).write(to: renamedCopy)
        try Data("different-image-data".utf8).write(to: different)

        let firstFingerprint = try ImageFingerprint.make(from: first)

        XCTAssertEqual(firstFingerprint, try ImageFingerprint.make(from: renamedCopy))
        XCTAssertNotEqual(firstFingerprint, try ImageFingerprint.make(from: different))
        XCTAssertEqual(firstFingerprint.byteSize, Int64(Data("same-image-data".utf8).count))
    }

    func testPhotoUploadHistoryStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseHistoryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PhotoUploadHistoryStore(rootURL: root)
        let record = UploadedPhotoRecord(
            contentHash: String(repeating: "a", count: 64),
            byteSize: 1234,
            originalFilename: "photo.heic",
            gyazoURL: "https://i.gyazo.com/example.jpg",
            capturedDate: "2026-09-03",
            uploadedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try store.save(record)

        XCTAssertEqual(store.record(for: record.contentHash), record)
        XCTAssertNil(store.record(for: "../invalid"))
    }

    func testPhotoUploadHistoryStoreFindsCurrentGyazoImageID() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseHistoryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PhotoUploadHistoryStore(rootURL: root)
        let record = UploadedPhotoRecord(
            contentHash: String(repeating: "b", count: 64),
            byteSize: 123,
            originalFilename: "photo.jpg",
            gyazoURL: "https://i.gyazo.com/current-id.jpg",
            gyazoImageID: "current-id",
            capturedDate: "2026-09-04",
            uploadedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(record)

        XCTAssertEqual(store.record(forGyazoImageID: "CURRENT-ID"), record)
    }

    func testPhotoUploadHistoryStoreFindsLegacyGyazoImageIDFromURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseHistoryTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PhotoUploadHistoryStore(rootURL: root)
        let record = UploadedPhotoRecord(
            contentHash: String(repeating: "c", count: 64),
            byteSize: 456,
            originalFilename: "legacy.jpg",
            gyazoURL: "https://i.gyazo.com/legacy-id.png",
            capturedDate: "2026-09-04",
            uploadedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.save(record)

        XCTAssertEqual(store.record(forGyazoImageID: "legacy-id"), record)
    }

    func testPhotoImportStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let store = PhotoImportStore(rootURL: root)
        let batch = PhotoImportBatch(
            id: UUID(),
            destination: .photo,
            projectName: "jindazs",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            items: [makeUploadedPhoto(index: 0, date: "2026-07-20", url: "https://i.gyazo.com/1.jpg")],
            state: .awaitingDecision
        )

        try store.save(batch)
        let loaded = try store.load(batch.id)

        XCTAssertEqual(loaded, batch)
    }

    func testPhotoImportStoreRecoversCopiedItemsAfterStagingInterruption() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PhotoImportStore(rootURL: root)
        let batch = PhotoImportBatch(
            id: UUID(),
            destination: .photo,
            projectName: "photos",
            createdAt: Date(),
            items: [makeStagedPhoto(index: 0)],
            state: .staging
        )
        try store.save(batch)

        let recovered = try store.recoverInterruptedStaging(batch.id)

        XCTAssertEqual(recovered.state, .staged)
        XCTAssertEqual(recovered.items.count, 1)
    }

    func testPhotoImportStoreDropsEmptyInterruptedStagingBatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PhotoImportStore(rootURL: root)
        let batch = PhotoImportBatch(
            id: UUID(),
            destination: .photo,
            projectName: "photos",
            createdAt: Date(),
            items: [],
            state: .staging
        )
        try store.save(batch)

        XCTAssertThrowsError(try store.recoverInterruptedStaging(batch.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(batch.id.uuidString).path))
    }

    func testPendingBatchesIncludesPausedWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogSenseTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = PhotoImportStore(rootURL: root)
        let batch = PhotoImportBatch(
            id: UUID(),
            destination: .primary,
            projectName: "main",
            createdAt: Date(),
            items: [makeStagedPhoto(index: 0)],
            state: .paused
        )
        try store.save(batch)

        XCTAssertEqual(store.pendingBatches().map(\.id), [batch.id])
    }

    private func makeUploadedPhoto(index: Int, date: String, url: String) -> PhotoImportItem {
        PhotoImportItem(
            id: UUID(),
            originalIndex: index,
            localFilename: "\(index).jpg",
            capturedDate: date,
            camera: "Camera",
            lens: "Lens",
            state: .uploaded,
            gyazoURL: url,
            attemptCount: 1,
            errorMessage: nil
        )
    }

    private func makeStagedPhoto(index: Int) -> PhotoImportItem {
        PhotoImportItem(
            id: UUID(),
            originalIndex: index,
            localFilename: "\(index).heic",
            capturedDate: "2026-09-03",
            camera: nil,
            lens: nil,
            state: .staged,
            gyazoURL: nil,
            attemptCount: 0,
            errorMessage: nil
        )
    }
}
