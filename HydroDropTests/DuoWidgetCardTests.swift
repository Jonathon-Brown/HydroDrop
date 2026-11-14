#if DUO_V2
import SwiftUI
import XCTest
@testable import HydroDrop

@MainActor
final class DuoWidgetCardTests: XCTestCase {
    func testCorruptAndLegacyCacheNeverProduceADuo() throws {
        let kit = DuoTestKit()
        let cache = DuoCache(defaults: kit.defaults)
        kit.defaults.set(Data("not JSON".utf8), forKey: DuoCache.statesKey)
        XCTAssertTrue(cache.loadDuos().isEmpty)
        kit.defaults.removeObject(forKey: DuoCache.statesKey)
        let oldDuo = DuoState(id: UUID(), myRole: .owner, createdAt: Date(), ownerDisplayName: "Jo",
                              partnerDisplayName: "Legacy partner", ownerSkin: "classic", partnerSkin: "forest",
                              statuses: [], partnerHasJoined: true)
        kit.defaults.set(try JSONEncoder().encode([oldDuo]), forKey: "duo.states.v1")
        XCTAssertTrue(cache.loadDuos().isEmpty)
        kit.defaults.removeObject(forKey: "duo.states.v1")
    }

    /// Finding 3: the partner's name, droplet and streak are marked private, so StandBy on a locked
    /// phone and a Mac on the same Apple ID redact them; the neutral states have nothing to hide.
    func testTheRunningCardIsRedactedForPrivacy() throws {
        let now = Date()
        let duo = DuoState(id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "Jo", partnerDisplayName: "Sam",
                           ownerSkin: "classic", partnerSkin: "forest", statuses: [], partnerHasJoined: true)
        func png(_ duos: [DuoState], age: DuoAgeStatus = .allowed, redacted: Bool) throws -> Data {
            let model = DuoWidgetModel.make(duos: duos, ageStatus: age, ageCheckUnavailable: false, now: now, snapshotDay: DayKey.key(for: now),
                                            snapshotTotalML: 1500, snapshotGoalML: 2000)
            let card = DuoWidgetCard(model: model).frame(width: 158, height: 158).background(.white)
            let renderer = ImageRenderer(content: Group { if redacted { card.redacted(reason: .privacy) } else { card } })
            renderer.scale = 1
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        XCTAssertNotEqual(try png([duo], redacted: true), try png([duo], redacted: false))
        XCTAssertEqual(try png([], redacted: true), try png([], redacted: false), "\"No duo yet\" names nobody")
        XCTAssertEqual(try png([], age: .refused, redacted: true), try png([], age: .refused, redacted: false))
    }

    func testAllSmallWidgetStatesRender() throws {
        let now = Date()
        var duo = DuoState(id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "Jo",
                           partnerDisplayName: "Sam", ownerSkin: "classic", partnerSkin: "forest",
                           statuses: [], partnerHasJoined: true)
        var samples: [(String, [DuoState])] = [("empty", []), ("running", [duo])]
        duo.partnerHasJoined = false; samples.append(("pending", [duo]))
        duo.partnerHasJoined = true; duo.partnerIsDemo = true; samples.append(("demo", [duo]))
        duo.partnerIsDemo = false; duo.partnerDisplayName = String(repeating: "A very long name ", count: 10)
        samples.append(("long-name", [duo]))
        duo.partnerDisplayName = "Sam"
        for offset in 0..<100 {
            let date = Calendar.current.date(byAdding: .day, value: -offset, to: now)!
            for role in DuoRole.allCases {
                duo.statuses.append(.init(role: role, day: DayKey.key(for: date), goalMet: true, progressBucket: 100, updatedAt: now))
            }
        }
        samples.append(("edge", [duo]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("duo-widget-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, duos) in samples {
            let model = DuoWidgetModel.make(duos: duos, ageStatus: .allowed, ageCheckUnavailable: false, now: now, snapshotDay: DayKey.key(for: now), snapshotTotalML: 1500, snapshotGoalML: 2000)
            let renderer = ImageRenderer(content: DuoWidgetCard(model: model).frame(width: 158, height: 158).background(.white))
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, name)
            XCTAssertEqual(image.size.width, 158)
            XCTAssertEqual(image.size.height, 158)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
            let large = ImageRenderer(content: DuoWidgetCard(model: model)
                .environment(\.dynamicTypeSize, .accessibility3).frame(width: 158, height: 158).background(.white))
            large.scale = 2
            try XCTUnwrap(large.uiImage?.pngData()).write(to: directory.appendingPathComponent("\(name)-large.png"))
            let inset = ImageRenderer(content: DuoWidgetCard(model: model)
                .environment(\.dynamicTypeSize, .accessibility3).frame(width: 126, height: 126).background(.white))
            inset.scale = 2
            try XCTUnwrap(inset.uiImage?.pngData()).write(to: directory.appendingPathComponent("\(name)-inset.png"))
        }
        print("Widget renders: \(directory.path)")
    }
}
#endif
