import UIKit
import XCTest
@testable import Browser

@MainActor
final class MainMenuTests: XCTestCase {
    /// Shortcuts typed while the address field or the sidebar has focus travel a responder chain
    /// that skips the browser and ends at the window, so the window must pass on every command.
    /// (UI tests can't type shortcuts: the CI simulator has no hardware keyboard.)
    func testWindowForwardsEveryMenuCommand() throws {
        let commands = MainMenu.allCommands
        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            let action = try XCTUnwrap(command.action, command.title)
            XCTAssertTrue(BrowserViewController.instancesRespond(to: action), "The browser doesn't handle \(action)")
            XCTAssertTrue(BrowserWindow.instancesRespond(to: action), "BrowserWindow doesn't forward \(action)")
        }
    }

    /// UIKit throws while building the menu if two commands share a shortcut.
    func testShortcutsAreUnique() {
        var seen: [String: String] = [:]
        for command in MainMenu.allCommands {
            let key = "\(command.modifierFlags.rawValue)-\(command.input ?? "")"
            if let other = seen[key] {
                XCTFail("\(command.title) and \(other) share a shortcut")
            }
            seen[key] = command.title
        }
    }
}
