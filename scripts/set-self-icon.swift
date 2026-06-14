import AppKit

// macOS 26 shrinks legacy .icns app icons onto a generic glass tile ("icon
// jail") unless the app ships an Icon Composer asset. A Finder custom icon —
// the same mechanism Dock Palette uses on other apps — escapes that, so
// install.sh re-applies one to MacBuddy itself after every fresh copy.
//
// Usage: swift set-self-icon.swift <app path> <icon png>

let appPath = CommandLine.arguments[1]
let iconPath = CommandLine.arguments[2]

guard let image = NSImage(contentsOf: URL(filePath: iconPath)) else {
    fatalError("could not load \(iconPath)")
}
guard NSWorkspace.shared.setIcon(image, forFile: appPath, options: []) else {
    fatalError("setIcon failed for \(appPath)")
}
// setIcon can set the custom-icon flag yet fail to write the Icon\r
// resource, which renders blank — verify like DockIconApplier does.
let iconFile = URL(filePath: appPath).appending(path: "Icon\r").path(percentEncoded: false)
guard FileManager.default.fileExists(atPath: iconFile) else {
    _ = NSWorkspace.shared.setIcon(nil, forFile: appPath, options: [])
    fatalError("Icon resource was not written")
}
try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: appPath)
print("custom icon set on \(appPath)")
