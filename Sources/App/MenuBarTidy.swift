import AppKit

/// Cleans up the menu bar AppKit ends up with.
///
/// SwiftUI's `commands` builder says what to add. The finished menu bar is
/// that merged with the standard macOS menus, and the merge leaves debris no
/// SwiftUI API can reach:
///
/// - Separators with nothing between them. Each `CommandGroup` gets its own
///   separator whether or not the group has any content, so emptied groups
///   collapse into doubled separators, and a group at the end of a menu leaves a
///   trailing one. Both draw as blank space.
/// - Duplicated system items. AppKit injects "Start Dictation…" and
///   "Emoji & Symbols" into Edit, and does it more than once (three copies of
///   Emoji & Symbols in this app).
/// - Commands for features that don't exist. "Toggle Sidebar" is added even
///   with no sidebar to toggle, and lands in Help.
/// - Empty menus. A menu with no items opens and instantly closes again,
///   and can't be reopened, so it reads as a broken app rather than an empty
///   menu.
///
/// The tidy re-runs every time the menu bar is clicked rather than once at
/// launch. SwiftUI rebuilds menus whenever the state behind a title changes,
/// several titles here are state-dependent ("Hide/Show Zoom Box",
/// the current rotation angle), and each rebuild brings the debris back.
/// Re-running is cheap.
enum MenuBarTidy {

    /// Actions for features this app doesn't have, whose menu items macOS adds
    /// anyway.
    ///
    /// Only items that exist before a menu displays can be removed this way.
    /// AppKit inserts some items between a menu being asked to display and
    /// the menu closing, after every hook available here, so window tabbing is
    /// handled at the source instead.
    private static let unwantedActions: Set<Selector> = [
        Selector(("toggleSidebar:")),
    ]

    static func install() {
        // Film Tether is a single-window app: there is one live view, tied to
        // one camera over one USB connection, so a second tab could only ever
        // show the same thing. This has to be switched off at the source rather
        // than filtered out below, because AppKit inserts "Hide Tab Bar" and
        // "Show All Tabs" while the menu is being displayed (see
        // unwantedActions). Measured: with tabbing on, they appear in View
        // no matter what the tidy does, and with it off they never appear at all.
        // It also keeps "Merge All Windows" and the rest out of the Window menu,
        // which otherwise grows from 4 items to 16.
        NSWindow.allowsAutomaticWindowTabbing = false

        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { note in
            // Only the menu bar. This notification fires for every menu, each
            // top-level menu as it opens, the pickers' pop-up menus, and the
            // system's submenus, and tidying those means touching menus we
            // don't own for no benefit.
            guard let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
            tidy(menu, isMenuBar: true)
        }
        tidy(NSApp.mainMenu, isMenuBar: true)
        // And again once SwiftUI has finished building the menu bar. The pass
        // above runs from `applicationDidFinishLaunching`, which is too early:
        // the menus barely exist yet, so it cleans almost nothing. These
        // delayed passes tidy the bar before the first click. They do not
        // remove the app menu's "Quit and Close All Windows", which renders as
        // a blank row on the first open: AppKit inserts it when the menu
        // displays (see unwantedActions).
        for delay in [0.5, 1.5, 3.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                tidy(NSApp.mainMenu, isMenuBar: true)
            }
        }
    }

    /// Tidy the menu bar's own menus, File, Edit, View and the rest, and
    /// nothing nested inside them.
    ///
    /// Not recursive. Reading `items` on a menu is what makes the system
    /// populate it, and the Services submenu populates by asking every
    /// application on the machine what it can do. Recursing into it can take
    /// 16 seconds on the first click of the app menu, long enough that the
    /// app appears to hang. Nothing this type fixes is ever nested anyway: the
    /// debris it removes sits at the top level of each menu, and the submenus
    /// below that belong to the system.
    static func tidy(_ menu: NSMenu?, isMenuBar: Bool = false) {
        guard let menu else { return }
        guard isMenuBar else {
            removeUnwanted(menu)
            removeDuplicates(menu)
            normalizeSeparators(menu)
            return
        }
        for item in menu.items {
            guard let sub = item.submenu else { continue }
            tidy(sub)
        }
        // A top-level title whose menu has nothing in it is worse than no title
        // at all, because it opens and dismisses itself.
        for item in menu.items where item.submenu?.items.isEmpty == true {
            menu.removeItem(item)
        }
    }

    private static func removeUnwanted(_ menu: NSMenu) {
        for item in menu.items where item.action.map(unwantedActions.contains) == true {
            menu.removeItem(item)
        }
    }

    /// Drop repeats of the same command, keeping the first. Matches on title and
    /// action together so two different items that happen to share a title
    /// survive.
    private static func removeDuplicates(_ menu: NSMenu) {
        var seen = Set<String>()
        for item in menu.items where !item.isSeparatorItem {
            let key = "\(item.title)\u{1}\(item.action.map(NSStringFromSelector) ?? "")"
            if !seen.insert(key).inserted { menu.removeItem(item) }
        }
    }

    /// A separator is only meaningful between two real items.
    private static func normalizeSeparators(_ menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true {
            menu.removeItem(at: 0)
        }
        while menu.items.last?.isSeparatorItem == true {
            menu.removeItem(at: menu.items.count - 1)
        }
        var i = menu.items.count - 1
        while i > 0 {
            if menu.items[i].isSeparatorItem, menu.items[i - 1].isSeparatorItem {
                menu.removeItem(at: i)
            }
            i -= 1
        }
    }
}
