import XCTest

/// Real-device checks of the share extension, driven through other apps' share
/// sheets. Not part of CI: run on a device by hand.
///
/// Shared items wait in the app group until Inkstone next opens, and then go
/// into whichever vault it opens. So every test ends by opening Inkstone on a
/// throwaway settings suite and the test vault (`qaLaunch`): a shared item must
/// never reach the person's own vault.
final class ShareFromOtherAppsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        // Even when a step fails after the item was queued, Inkstone opens on
        // the QA suite before anything else can drain the queue.
        addTeardownBlock { [weak self] in self?.qaLaunch() }
    }

    /// Inkstone on the QA settings suite with the test vault open, which
    /// drains the shared items into that vault.
    private func qaLaunch() {
        let app = XCUIApplication()
        app.launchEnvironment = [
            "INKSTONE_DEMO_DEFAULTS": "com.orris.inkstone.qa",
            "INKSTONE_OPEN_VAULT": "qa-vault",
        ]
        app.launch()
        sleep(8)
    }

    /// The first element whose label is `label`, tapped; the tree is printed
    /// when it is not there, so the next run can be corrected.
    private func tap(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 10,
                     file: StaticString = #filePath, line: UInt = #line) {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
        if !element.waitForExistence(timeout: timeout) {
            print("=== TREE (looking for \(label)) ===\n\(app.debugDescription)")
            XCTFail("no element labelled \(label)", file: file, line: line)
        }
        element.tap()
    }

    /// In the share sheet: Inkstone's icon in the row of apps. Only cells
    /// identified as `shareCell` (apps) are ever touched — the row above holds
    /// people and AirDrop targets, and a tap there would send the item.
    private func pickInkstone(in host: XCUIApplication) {
        let apps = host.cells.matching(identifier: "shareCell")
        XCTAssertTrue(apps.firstMatch.waitForExistence(timeout: 10), "no row of apps in the share sheet")
        let inkstone = apps.matching(NSPredicate(format: "label == 'Inkstone'")).firstMatch
        let labels = (0..<apps.count).map { i -> String in
            let cell = apps.element(boundBy: i); return "\(cell.label)\(cell.isHittable ? "" : " (hidden)")"
        }
        print("=== APP ROW: \(labels)")
        for _ in 0..<8 where !(inkstone.exists && inkstone.isHittable) {
            // Swiped on an app cell that is on screen; swiping never opens one.
            // A drag along the row by screen coordinates, starting on the
            // second app's icon: element swipes fail here ("visible frame is
            // empty") although the cells are on screen.
            let frame = apps.element(boundBy: 1).frame
            let window = host.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            let start = window.withOffset(CGVector(dx: frame.maxX + 150, dy: frame.midY - 20))
            let end = window.withOffset(CGVector(dx: frame.minX - 60, dy: frame.midY - 20))
            start.press(forDuration: 0.05, thenDragTo: end)
            sleep(1)
        }
        if inkstone.exists && inkstone.isHittable { inkstone.tap(); return }
        let more = apps.matching(NSPredicate(format: "label == 'More'")).firstMatch
        if more.exists {
            more.tap(); sleep(3)
            // The full list of apps: one row per app, by name. Only a row
            // whose label is exactly "Inkstone" is touched.
            let row = host.descendants(matching: .any).matching(NSPredicate(format: "label == 'Inkstone' AND identifier != 'shareCell'")).firstMatch
            for _ in 0..<6 where !(row.exists && row.isHittable) {
                host.swipeUp(); sleep(1)
            }
            if row.exists && row.isHittable { row.tap(); return }
            print("=== TREE (after More) ===\n\(host.debugDescription)")
        }
        XCTFail("Inkstone is not in the share sheet's row of apps")
    }

    private func saveInExtension(host: XCUIApplication) {
        // The extension's sheet is shown inside the host app's process.
        let save = host.buttons["Save"]
        if !save.waitForExistence(timeout: 15) {
            print("=== TREE (looking for Save) ===\n\(host.debugDescription)")
            XCTFail("no Save button in the Inkstone share sheet")
        }
        save.tap()
        sleep(3)
    }

    func testShareWebPageFromSafari() throws {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(URL(string: "https://example.com/?inkstone-qa")!)
        sleep(4)
        tap("MoreMenuButton", in: safari)
        tap("Share", in: safari)
        pickInkstone(in: safari)
        saveInExtension(host: safari)
    }

    func testShareLivePhotoFromPhotos() throws { try sharePhoto(kind: "Live Photo,") }
    func testShareStillPhotoFromPhotos() throws { try sharePhoto(kind: "Photo,") }

    /// The first on-screen library item of a kind ("Live Photo," or "Photo,"
    /// — the grid's labels start with the kind), shared into Inkstone.
    private func sharePhoto(kind: String) throws {
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.launch()
        sleep(3)
        let items = photos.images.matching(NSPredicate(format: "identifier == 'PXGGridLayout-Info' AND label BEGINSWITH %@", kind))
        let item = (0..<items.count).map { items.element(boundBy: $0) }.first { $0.isHittable && $0.frame.minY > 100 }
        guard let item else { XCTFail("no \(kind) on screen"); return }
        item.tap()
        let share = photos.buttons.matching(NSPredicate(format: "label == 'Share' OR identifier == 'Share'")).firstMatch
        if !share.waitForExistence(timeout: 8) {
            print("=== TREE (viewer) ===\n\(photos.debugDescription)")
            XCTFail("no Share button in the photo viewer"); return
        }
        share.tap()
        pickInkstone(in: photos)
        saveInExtension(host: photos)
    }
}
