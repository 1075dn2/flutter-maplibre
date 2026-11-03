import Foundation
import XCTest
@testable import ScopedPolicy

final class ScopedRequestPolicyTests: XCTestCase {
    let base: [String: Any] = ["Host": "tiles.example.com", "PathPrefix": "/tiles/", "Headers": ["Accept": "image/png", "User-Agent": "TestApp/1"]]
    func testExactScope() throws {
        let p = try XCTUnwrap(ScopedRequestPolicy(configuration: base))
        XCTAssertTrue(p.matches(URL(string: "https://TILES.example.com/tiles/1.png")))
        XCTAssertTrue(p.matches(URL(string: "https://tiles.example.com:443/tiles/1.png")))
        for url in ["http://tiles.example.com/tiles/1.png", "https://tiles.example.com:444/tiles/1.png", "https://tiles.example.com.evil/tiles/1.png", "https://user@tiles.example.com/tiles/1.png", "https://evil/tiles/tiles.example.com", "https://tiles.example.com/other/1.png", "https://tiles.example.com/tiles/%2e%2e/other", "https://tiles.example.com/tiles/1.png#fragment"] {
            XCTAssertFalse(p.matches(URL(string: url)), url)
        }
    }
    func testHeadersPreserveValidatorsAndUnrelatedRequests() throws {
        let p = try XCTUnwrap(ScopedRequestPolicy(configuration: base))
        var request = URLRequest(url: URL(string: "https://tiles.example.com/tiles/1.png")!)
        request.setValue("tag", forHTTPHeaderField: "If-None-Match")
        request.setValue("bytes=0-100", forHTTPHeaderField: "Range")
        let applied = p.apply(to: request)
        XCTAssertEqual(applied.value(forHTTPHeaderField: "Accept"), "image/png")
        XCTAssertEqual(applied.value(forHTTPHeaderField: "If-None-Match"), "tag")
        XCTAssertEqual(applied.value(forHTTPHeaderField: "Range"), "bytes=0-100")
        let glyph = URLRequest(url: URL(string: "https://glyphs.example.com/font.pbf")!)
        XCTAssertEqual(p.apply(to: glyph), glyph)
    }
    func testRedirectsStayInScope() throws {
        let p = try XCTUnwrap(ScopedRequestPolicy(configuration: base))
        let original = URLRequest(url: URL(string: "https://tiles.example.com/tiles/1.png")!)
        XCTAssertNotNil(p.redirect(original: original, current: original, proposed: URLRequest(url: URL(string: "https://tiles.example.com/tiles/2.png")!)))
        for target in ["https://evil/tiles/2.png", "http://tiles.example.com/tiles/2.png", "https://tiles.example.com/other/2.png"] {
            XCTAssertNil(p.redirect(original: original, current: original, proposed: URLRequest(url: URL(string: target)!)))
        }
        let unrelated = URLRequest(url: URL(string: "https://glyphs.example.com/font.pbf")!)
        XCTAssertEqual(p.redirect(original: unrelated, current: unrelated, proposed: unrelated), unrelated)
        // A chain which entered provider scope cannot carry headers back out.
        XCTAssertNil(p.redirect(original: unrelated, current: original, proposed: unrelated))
    }
    func testRejectsCredentialAndMalformedConfiguration() {
        for headers in [["Authorization": "secret"], ["Accept": "x\r\ny"], ["Accept": "x", "accept": "y"]] {
            var config = base
            config["Headers"] = headers
            XCTAssertNil(ScopedRequestPolicy(configuration: config))
        }
    }
}
