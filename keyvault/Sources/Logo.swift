import AppKit

enum Logo {
    static let image: NSImage = {
        if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
           let img = NSImage(contentsOf: url) { return img }
        return NSApp.applicationIconImage
    }()
}
