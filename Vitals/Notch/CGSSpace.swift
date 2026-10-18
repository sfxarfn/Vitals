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
// way to weld it to the screen — and adding it there is not the weld. It also
// has to leave the desktop, or the swipe still has a membership to translate.

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
            // Adding does not take the panel off the desktop it was ordered
            // onto. An unchanged set never gets here, so a bare reorder has
            // to call `stick()` itself.
            stick()
        }
    }

    /// Takes every managed-Space membership away from `windows`.
    ///
    /// `canJoinAllSpaces` only catches up once the gesture ends, so a panel
    /// that is still on a desktop rides that desktop for the whole swipe: the
    /// animation, a half swipe that gets cancelled, Mission Control, App
    /// Exposé, and the move into a full-screen Space. `CGSAddWindowsToSpaces`
    /// does not touch that membership. Mask `managedSpaces` is every desktop
    /// and full-screen Space; this space is not one of them, so the panel is
    /// left only here, which the transition does not transform.
    func stick() {
        let numbers = windows.compactMap { window -> NSNumber? in
            let number = window.windowNumber
            guard number > 0 else { return nil }
            return NSNumber(value: number)
        }
        guard !numbers.isEmpty, let claim = Self.claimWindows else { return }
        claim(Int32(truncatingIfNeeded: _CGSDefaultConnection()),
              identifier,
              numbers as CFArray,
              Self.managedSpaces)
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

    /// `CGSSpaceIncludesCurrent | CGSSpaceIncludesOthers | CGSSpaceIncludesUser`.
    /// Every Space the window server animates. The private space is not in it.
    private static let managedSpaces: Int32 = 0x7

    /// Resolved at runtime: the symbol is in SkyLight, which this target does
    /// not link, and a miss has to leave the old add-only behavior in place
    /// rather than dropping the panel off the screen.
    private static let claimWindows: ClaimWindows? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let sym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces") else {
            #if DEBUG
            NSLog("Vitals notch: SLSSpaceAddWindowsAndRemoveFromSpaces unavailable; the panel will ride a space swipe")
            #endif
            return nil
        }
        return unsafeBitCast(sym, to: ClaimWindows.self)
    }()
}

private typealias CGSConnectionID = UInt
private typealias CGSSpaceID = UInt64

/// `(connection, space, windows, spaceMask) -> void`. The mask names the
/// Spaces to take the windows off while they are added to `space`.
private typealias ClaimWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Void

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
