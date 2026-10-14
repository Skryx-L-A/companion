// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import CoreGraphics
import XCTest

@testable import CompanionUI

/// Two screens, made up. The desk this is modelled on is a built-in display with the menu bar
/// and a wider one standing to the right of it — which is the arrangement the figure went to
/// the wrong screen on.
private enum Desk {
    static let builtIn = ScreenDescriptor(
        displayID: 1, localizedName: "Built-in Retina Display",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        hasMenuBar: true)

    static let external = ScreenDescriptor(
        displayID: 2, localizedName: "DELL U2723QE",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
        hasMenuBar: false)

    static let both = [builtIn, external]
}

final class ScreenPlacementTests: XCTestCase {
    func testTheDefaultIsTheScreenWithTheMenuBar() {
        let resolved = ScreenPlacement.resolve(.automatic, among: Desk.both)
        XCTAssertEqual(resolved?.screen, Desk.builtIn)
        XCTAssertEqual(resolved?.isSubstitute, false)
    }

    /// The list order must not decide it: AppKit puts the menu bar screen first, but a hand
    /// built list may not, and the flag is what the choice means.
    func testTheDefaultFollowsTheMenuBarAndNotTheOrder() {
        let resolved = ScreenPlacement.resolve(.automatic, among: [Desk.external, Desk.builtIn])
        XCTAssertEqual(resolved?.screen, Desk.builtIn)
    }

    func testAPickedScreenIsFoundByItsName() {
        let choice = ScreenPlacement.choice(for: Desk.external)
        let resolved = ScreenPlacement.resolve(choice, among: Desk.both)
        XCTAssertEqual(resolved?.screen, Desk.external)
        XCTAssertEqual(resolved?.isSubstitute, false)
    }

    /// The same monitor on another port comes back with another display id and keeps its name.
    /// That is the case the name half of the identity exists for.
    func testANewDisplayIdIsNotANewScreen() {
        let choice = ScreenChoice.specific(name: Desk.external.localizedName, displayID: 99)
        let resolved = ScreenPlacement.resolve(choice, among: Desk.both)
        XCTAssertEqual(resolved?.screen, Desk.external)
        XCTAssertEqual(resolved?.isSubstitute, false)
    }

    /// Two screens of the same model share their name, and then the display id is the only
    /// thing that tells them apart.
    func testTwoScreensOfTheSameModelAreToldApartByTheirDisplayId() {
        let twin = ScreenDescriptor(
            displayID: 3, localizedName: Desk.external.localizedName,
            frame: CGRect(x: 4072, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 4072, y: 0, width: 2560, height: 1415),
            hasMenuBar: false)
        let choice = ScreenPlacement.choice(for: twin)
        let resolved = ScreenPlacement.resolve(choice, among: [Desk.builtIn, Desk.external, twin])
        XCTAssertEqual(resolved?.screen, twin)
    }

    /// A screen that was renamed in the system settings is still the screen it was.
    func testARenamedScreenIsFoundByItsDisplayId() {
        let choice = ScreenChoice.specific(name: "Der alte Name", displayID: Desk.external.displayID)
        let resolved = ScreenPlacement.resolve(choice, among: Desk.both)
        XCTAssertEqual(resolved?.screen, Desk.external)
    }

    func testAnAbsentScreenFallsBackToTheDefaultAndSaysSo() {
        let choice = ScreenPlacement.choice(for: Desk.external)
        let resolved = ScreenPlacement.resolve(choice, among: [Desk.builtIn])
        XCTAssertEqual(resolved?.screen, Desk.builtIn)
        XCTAssertEqual(resolved?.isSubstitute, true)
    }

    func testNoScreenAtAllResolvesToNothing() {
        XCTAssertNil(ScreenPlacement.resolve(.automatic, among: []))
        XCTAssertNil(ScreenPlacement.resolve(ScreenPlacement.choice(for: Desk.builtIn), among: []))
    }
}

@MainActor
final class OverlayScreenPlacementTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    /// What the controller is told is attached. Written by the test, read through the list the
    /// controller was handed — this is the second monitor, without a second monitor.
    private var attached: [ScreenDescriptor] = Desk.both

    override func setUp() {
        super.setUp()
        suiteName = "companion.screen.\(fixedSuiteSuffix)"
        defaults = UserDefaults(suiteName: suiteName)
        attached = Desk.both
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeController() -> OverlayController {
        let list = ScreenList(provider: { [unowned self] in self.attached })
        return OverlayController(
            settings: AppSettings(defaults: defaults), spriteFolder: nil, screens: list)
    }

    private let windowSize = CGSize(width: 340, height: 104)

    func testTheCornerIsReadOnTheChosenScreen() {
        let controller = makeController()
        controller.setScreenChoice(ScreenPlacement.choice(for: Desk.external))
        controller.setCorner(.bottomTrailing)

        let frame = controller.panelFrame(for: windowSize)
        XCTAssertTrue(
            Desk.external.visibleFrame.contains(frame),
            "the figure landed at \(frame), outside the chosen screen")
        XCTAssertEqual(frame.maxX, Desk.external.visibleFrame.maxX - 16)
        XCTAssertEqual(frame.minY, Desk.external.visibleFrame.minY + 16)
    }

    /// Every corner on every screen, because the second screen is the one whose frame does not
    /// start at zero — an origin computed against the wrong screen shows up here and nowhere
    /// else.
    func testEveryCornerLandsOnTheScreenItWasPickedFor() {
        let controller = makeController()
        for screen in Desk.both {
            controller.setScreenChoice(ScreenPlacement.choice(for: screen))
            for corner in ScreenCorner.allCases {
                controller.setCorner(corner)
                let frame = controller.panelFrame(for: windowSize)
                XCTAssertTrue(
                    screen.visibleFrame.contains(frame),
                    "\(corner) on \(screen.localizedName) landed at \(frame)")
            }
        }
    }

    func testWithoutAChoiceTheFigureSitsOnTheScreenWithTheMenuBar() {
        let controller = makeController()
        controller.setCorner(.bottomTrailing)
        XCTAssertTrue(Desk.builtIn.visibleFrame.contains(controller.panelFrame(for: windowSize)))
    }

    /// The one the task is about: unplug, the figure moves to the default screen, and the
    /// choice stays. Plug in, and it goes back on its own.
    func testUnpluggingMovesTheFigureAndKeepsTheChoice() {
        let controller = makeController()
        controller.setScreenChoice(ScreenPlacement.choice(for: Desk.external))
        controller.setCorner(.bottomTrailing)
        XCTAssertTrue(Desk.external.visibleFrame.contains(controller.panelFrame(for: windowSize)))

        attached = [Desk.builtIn]
        controller.refreshScreens()

        XCTAssertEqual(controller.screenResolution?.screen, Desk.builtIn)
        XCTAssertEqual(controller.screenResolution?.isSubstitute, true)
        XCTAssertTrue(
            Desk.builtIn.visibleFrame.contains(controller.panelFrame(for: windowSize)),
            "the figure stayed on a screen that is not there")
        XCTAssertEqual(
            controller.settings.screenChoice, ScreenPlacement.choice(for: Desk.external),
            "the choice was overwritten while the screen was away")

        attached = Desk.both
        controller.refreshScreens()

        XCTAssertEqual(controller.screenResolution?.screen, Desk.external)
        XCTAssertEqual(controller.screenResolution?.isSubstitute, false)
        XCTAssertTrue(Desk.external.visibleFrame.contains(controller.panelFrame(for: windowSize)))
    }

    /// The same monitor after a reboot of the dock: the name is the one that was picked, the
    /// display id is not. It must count as the same screen, not as a screen that went away.
    /// The picker in the settings tags every row with the id the screen has right now. A
    /// choice that still carries the old id matches no row, and the popup then shows nothing
    /// as picked while the figure sits exactly where it should. So the id that was found is
    /// written back.
    func testTheChoiceTakesOverTheNewDisplayIdOfTheSameScreen() {
        let controller = makeController()
        controller.setScreenChoice(ScreenPlacement.choice(for: Desk.external))

        let renumbered = ScreenDescriptor(
            displayID: 77, localizedName: Desk.external.localizedName,
            frame: Desk.external.frame, visibleFrame: Desk.external.visibleFrame,
            hasMenuBar: false)
        attached = [Desk.builtIn, renumbered]
        controller.refreshScreens()

        XCTAssertEqual(
            controller.settings.screenChoice, ScreenPlacement.choice(for: renumbered),
            "the choice still names the id the screen had yesterday")
        XCTAssertEqual(
            AppSettings(defaults: defaults).screenChoice, ScreenPlacement.choice(for: renumbered),
            "and the corrected choice was not kept")
    }

    /// The one the resolution cannot get right on its own: two monitors of the same model, and
    /// the stored id belongs to neither of them any more. The first of the two is taken, and
    /// the choice is corrected to whatever was taken — so the next unplugging starts from an id
    /// that exists rather than from the one that went stale.
    func testTwoTwinsAndAStoredIdThatMatchesNeither() {
        let first = ScreenDescriptor(
            displayID: 10, localizedName: "DELL U2723QE",
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415),
            hasMenuBar: false)
        let second = ScreenDescriptor(
            displayID: 11, localizedName: "DELL U2723QE",
            frame: CGRect(x: 4072, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 4072, y: 0, width: 2560, height: 1415),
            hasMenuBar: false)
        let controller = makeController()
        controller.setScreenChoice(.specific(name: "DELL U2723QE", displayID: 2))

        attached = [Desk.builtIn, first, second]
        controller.refreshScreens()

        XCTAssertEqual(controller.screenResolution?.screen, first, "the first of the two is taken")
        XCTAssertEqual(
            controller.screenResolution?.isSubstitute, false,
            "a screen of the right model was found, so nothing is standing in")
        XCTAssertEqual(
            controller.settings.screenChoice, ScreenPlacement.choice(for: first),
            "the choice kept an id that belongs to no screen")
    }

    /// And nothing is written back while the screen is away: the stale pair is what brings the
    /// figure home.
    func testTheChoiceIsLeftAloneWhileTheScreenIsAway() {
        let controller = makeController()
        controller.setScreenChoice(ScreenPlacement.choice(for: Desk.external))

        attached = [Desk.builtIn]
        controller.refreshScreens()

        XCTAssertEqual(
            controller.settings.screenChoice, ScreenPlacement.choice(for: Desk.external))
        XCTAssertEqual(
            AppSettings(defaults: defaults).screenChoice,
            ScreenPlacement.choice(for: Desk.external))
    }

    func testTheScreenComesBackWithANewDisplayId() {
        let controller = makeController()
        controller.setScreenChoice(ScreenPlacement.choice(for: Desk.external))

        let renumbered = ScreenDescriptor(
            displayID: 77, localizedName: Desk.external.localizedName,
            frame: Desk.external.frame, visibleFrame: Desk.external.visibleFrame,
            hasMenuBar: false)
        attached = [Desk.builtIn, renumbered]
        controller.refreshScreens()

        XCTAssertEqual(controller.screenResolution?.screen, renumbered)
        XCTAssertEqual(controller.screenResolution?.isSubstitute, false)
    }

    func testTheChoiceSurvivesARestart() {
        let controller = makeController()
        controller.setScreenChoice(ScreenPlacement.choice(for: Desk.external))
        XCTAssertEqual(
            AppSettings(defaults: defaults).screenChoice,
            ScreenPlacement.choice(for: Desk.external))

        controller.setScreenChoice(.automatic)
        XCTAssertEqual(AppSettings(defaults: defaults).screenChoice, .automatic)
    }
}

final class ScreenArrangementTests: XCTestCase {
    private let box = CGSize(width: 180, height: 64)

    func testEveryScreenStaysInsideTheBox() {
        let miniatures = ScreenArrangement.miniatures(for: Desk.both, in: box)
        XCTAssertEqual(miniatures.count, 2)
        let bounds = CGRect(origin: .zero, size: box)
        for miniature in miniatures {
            XCTAssertTrue(
                bounds.insetBy(dx: -0.01, dy: -0.01).contains(miniature.rect),
                "\(miniature.rect) is not inside \(bounds)")
        }
    }

    func testTheArrangementKeepsTheSidesItHasOnTheDesk() {
        let miniatures = ScreenArrangement.miniatures(for: Desk.both, in: box)
        let builtIn = miniatures.first { $0.displayID == Desk.builtIn.displayID }
        let external = miniatures.first { $0.displayID == Desk.external.displayID }
        XCTAssertNotNil(builtIn)
        XCTAssertNotNil(external)
        XCTAssertLessThan(builtIn!.rect.minX, external!.rect.minX, "the screens swapped sides")
        XCTAssertGreaterThan(
            external!.rect.height, builtIn!.rect.height,
            "the taller screen did not stay the taller one")
    }

    func testAScreenKeepsItsProportions() {
        let miniature = ScreenArrangement.miniatures(for: [Desk.external], in: box)[0]
        let deskRatio = Desk.external.frame.width / Desk.external.frame.height
        XCTAssertEqual(miniature.rect.width / miniature.rect.height, deskRatio, accuracy: 0.001)
    }

    /// A screen standing above another one has to appear above it, and AppKit counts upwards
    /// while the preview is drawn downwards.
    func testTheVerticalAxisIsFlippedForDrawing() {
        let above = ScreenDescriptor(
            displayID: 5, localizedName: "Oben",
            frame: CGRect(x: 0, y: 982, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 982, width: 1512, height: 944),
            hasMenuBar: false)
        let miniatures = ScreenArrangement.miniatures(for: [Desk.builtIn, above], in: box)
        let lower = miniatures.first { $0.displayID == Desk.builtIn.displayID }!
        let upper = miniatures.first { $0.displayID == above.displayID }!
        XCTAssertLessThan(upper.rect.minY, lower.rect.minY)
    }

    func testAnEmptyDeskDrawsNothing() {
        XCTAssertTrue(ScreenArrangement.miniatures(for: [], in: box).isEmpty)
        XCTAssertTrue(ScreenArrangement.miniatures(for: Desk.both, in: .zero).isEmpty)
    }

    func testTheDotSitsInTheCornerItNames() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        let inset: CGFloat = 5
        XCTAssertEqual(
            ScreenArrangement.dot(for: .topLeading, in: rect, inset: inset), CGPoint(x: 15, y: 25))
        XCTAssertEqual(
            ScreenArrangement.dot(for: .topTrailing, in: rect, inset: inset), CGPoint(x: 105, y: 25))
        XCTAssertEqual(
            ScreenArrangement.dot(for: .bottomLeading, in: rect, inset: inset),
            CGPoint(x: 15, y: 65))
        XCTAssertEqual(
            ScreenArrangement.dot(for: .bottomTrailing, in: rect, inset: inset),
            CGPoint(x: 105, y: 65))
    }
}

/// The one place where AppKit is actually asked. Everything above works on made-up screens, so
/// without this nobody would notice if `NSScreen` stopped answering the way it is read here.
@MainActor
final class AttachedScreenTests: XCTestCase {
    func testTheMachineDescribesItsOwnScreens() throws {
        let screens = ScreenDescriptor.attached()
        try XCTSkipIf(screens.isEmpty, "This run has no screen at all.")
        XCTAssertEqual(
            screens.filter(\.hasMenuBar).count, 1, "exactly one screen carries the menu bar")
        for screen in screens {
            XCTAssertFalse(screen.localizedName.isEmpty, "a screen without a name cannot be picked")
            XCTAssertNotEqual(screen.displayID, 0, "a screen without a display id has no fallback")
            XCTAssertTrue(
                screen.frame.contains(screen.visibleFrame),
                "\(screen.localizedName): the usable part is not inside the screen")
        }
    }

    /// And the figure lands on the real screen of this machine, in the corner it was told.
    func testTheFigureLandsOnThisMachinesScreen() throws {
        let screens = ScreenDescriptor.attached()
        try XCTSkipIf(screens.isEmpty, "This run has no screen at all.")
        let suite = "companion.screen.\(fixedSuiteSuffix)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = OverlayController(
            settings: AppSettings(defaults: defaults), spriteFolder: nil)

        for screen in screens {
            controller.setScreenChoice(ScreenPlacement.choice(for: screen))
            for corner in ScreenCorner.allCases {
                controller.setCorner(corner)
                let frame = controller.panelFrame(for: CGSize(width: 340, height: 104))
                XCTAssertTrue(
                    screen.visibleFrame.contains(frame),
                    "\(corner) on \(screen.localizedName) landed at \(frame)")
            }
        }
    }
}
