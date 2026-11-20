//
//  CGSSpace.swift
//  Vitals
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.
//
// Original source: https://github.com/avaidyam/Parrot/
// Via: https://github.com/TheBoredTeam/boring.notch
//
// Private Spaces API. There is no public equivalent: a window can be told to
// appear on all spaces, but it still *belongs* to one, which is what drags it
// along during a swipe. Putting it in a private space of its own is the only
// way to weld it to the screen.

import AppKit

/// Small Spaces API wrapper.
final class CGSSpace {
    private let identifier: CGSSpaceID

    var windows: Set<NSWindow> = [] {
        didSet {
            let remove = oldValue.subtracting(windows)
            let add = windows.subtracting(oldValue)
            CGSRemoveWindowsFromSpaces(_CGSDefaultConnection(),
                                       remove.map(\.windowNumber) as NSArray,
                                       [identifier])
            CGSAddWindowsToSpaces(_CGSDefaultConnection(),
                                  add.map(\.windowNumber) as NSArray,
                                  [identifier])
        }
    }

    init(level: Int = 0) {
        let flag = 0x1  // MUST be 1, or Finder starts drawing desktop icons into it
        identifier = CGSSpaceCreate(_CGSDefaultConnection(), flag, nil)
        CGSSpaceSetAbsoluteLevel(_CGSDefaultConnection(), identifier, level)
        CGSShowSpaces(_CGSDefaultConnection(), [identifier])
    }

    deinit {
        CGSHideSpaces(_CGSDefaultConnection(), [identifier])
        CGSSpaceDestroy(_CGSDefaultConnection(), identifier)
    }
}

// MARK: Cursor

/// WindowServer applies cursor changes only from the active app. Vitals is an
/// accessory that never activates — the panel is non-activating so typing
/// stays where it was — so `NSCursor.set()` from its tracking areas was
/// overridden by the frontmost app's own cursor on the next mouse move, and
/// the pointing hand never showed. This connection property opts the app's
/// connection into setting the cursor while in the background. Private, like
/// the rest of this file; there is no public switch.
enum CGSCursor {
    static func setInBackground() {
        let cid = _CGSDefaultConnection()
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

@_silgen_name("_CGSDefaultConnection")
private func _CGSDefaultConnection() -> CGSConnectionID
@_silgen_name("CGSSpaceCreate")
private func CGSSpaceCreate(_ cid: CGSConnectionID, _ unknown: Int, _ options: NSDictionary?) -> CGSSpaceID
@_silgen_name("CGSSpaceDestroy")
private func CGSSpaceDestroy(_ cid: CGSConnectionID, _ space: CGSSpaceID)
@_silgen_name("CGSSpaceSetAbsoluteLevel")
private func CGSSpaceSetAbsoluteLevel(_ cid: CGSConnectionID, _ space: CGSSpaceID, _ level: Int)
@_silgen_name("CGSAddWindowsToSpaces")
private func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSRemoveWindowsFromSpaces")
private func CGSRemoveWindowsFromSpaces(_ cid: CGSConnectionID, _ windows: NSArray, _ spaces: NSArray)
@_silgen_name("CGSHideSpaces")
private func CGSHideSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSShowSpaces")
private func CGSShowSpaces(_ cid: CGSConnectionID, _ spaces: NSArray)
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: CGSConnectionID, _ target: CGSConnectionID,
                                      _ key: CFString, _ value: CFTypeRef) -> Int32
