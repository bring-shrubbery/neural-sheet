import CoreText
import Foundation

/// Registers the TTF files bundled with the app so SwiftUI can reference them by family name.
enum FontRegistry {
    static func registerBundledFonts() {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) else { return }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
