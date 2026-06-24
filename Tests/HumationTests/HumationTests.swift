import CoreGraphics
import XCTest

@testable import Humation

final class HumationTests: XCTestCase {

    // MARK: FNV-1a parity (byte-identical to the reference TypeScript engine)

    func testFNV1aKnownVectors() {
        // Computed with the reference algorithm (UTF-16 code units, 32-bit wrap).
        XCTAssertEqual(HumationEngine.fnv1a(""), 2_166_136_261)
        XCTAssertEqual(HumationEngine.fnv1a("a"), 3_826_002_220)
        XCTAssertEqual(HumationEngine.fnv1a("test"), 2_949_673_445)
        XCTAssertEqual(HumationEngine.fnv1a("humation"), 2_721_276_410)
        XCTAssertEqual(HumationEngine.fnv1a("用户"), 3_303_804_768) // CJK → UTF-16 path
        XCTAssertEqual(HumationEngine.fnv1a("hm1"), 1_204_328_429)
    }

    func testNormalizeHex() {
        XCTAssertEqual(HumationEngine.normalizeHex("#aabbcc"), "AABBCC")
        XCTAssertEqual(HumationEngine.normalizeHex("aabbcc"), "AABBCC")
        XCTAssertEqual(HumationEngine.normalizeHex("transparent"), "transparent")
        XCTAssertEqual(HumationEngine.normalizeHex("TRANSPARENT"), "transparent")
    }

    // MARK: Manifest

    func testBundledManifestLoads() throws {
        let manifest = try XCTUnwrap(HumationManifestStore.shared, "bundled humation-1.json missing")
        XCTAssertEqual(manifest.parts.count, 86)
        XCTAssertEqual(manifest.parts(in: .head).count, 24)
        XCTAssertEqual(manifest.parts(in: .body).count, 8)
        XCTAssertEqual(manifest.parts(in: .item).count, 43) // 32 items + 11 cats
        XCTAssertEqual(manifest.parts(in: .glasses).count, 3)
        XCTAssertNotNil(manifest.part(id: manifest.defaults.selections["head"]!))
    }

    // MARK: Determinism

    func testResolveIsDeterministic() throws {
        let manifest = try XCTUnwrap(HumationManifestStore.shared)
        let a = HumationTraits(seed: "user-123").resolved(against: manifest)
        let b = HumationTraits(seed: "user-123").resolved(against: manifest)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.cacheToken, b.cacheToken)
        // Different seeds should (almost always) differ.
        let c = HumationTraits(seed: "user-456").resolved(against: manifest)
        XCTAssertNotEqual(a.selections, c.selections)
    }

    func testExplicitSelectionOverridesSeed() throws {
        let manifest = try XCTUnwrap(HumationManifestStore.shared)
        let head = manifest.parts(in: .head).last!.id
        var traits = HumationTraits(seed: "x")
        traits.selections[.head] = head
        XCTAssertEqual(traits.resolved(against: manifest).selections[.head], head)
    }

    // MARK: Render smoke

    func testRenderProducesImage() throws {
        let manifest = try XCTUnwrap(HumationManifestStore.shared)
        let resolved = HumationTraits(seed: "render").resolved(against: manifest)
        let image = try XCTUnwrap(
            HumationRenderer.render(resolved: resolved, manifest: manifest, pixels: 128)
        )
        XCTAssertEqual(image.width, 128)
        XCTAssertEqual(image.height, 128)
    }

    func testBundledManifestIsValid() throws {
        let manifest = try XCTUnwrap(HumationManifestStore.shared)
        let issues = HumationValidator.validate(manifest)
        XCTAssertTrue(issues.isEmpty, "bundled pack has issues: \(issues)")
    }

    func testFacadeProducesImage() {
        XCTAssertNotNil(Humation.cgImage(seed: "facade", pixels: 96))
        XCTAssertNotNil(Humation.resolved(seed: "facade"))
    }

    func testContentBoundsForItem() throws {
        let manifest = try XCTUnwrap(HumationManifestStore.shared)
        // A real item (not the empty "none") should have non-zero content bounds.
        let item = try XCTUnwrap(manifest.parts(in: .item).first { $0.name != "none" })
        let bounds = try XCTUnwrap(HumationRenderer.contentBounds(of: item, in: manifest))
        XCTAssertGreaterThan(bounds.width, 0)
        XCTAssertGreaterThan(bounds.height, 0)

        // The empty "none" item has no drawn content.
        if let none = manifest.parts(in: .item).first(where: { $0.name == "none" }) {
            XCTAssertNil(HumationRenderer.contentBounds(of: none, in: manifest))
        }
    }
}
