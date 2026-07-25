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
}
