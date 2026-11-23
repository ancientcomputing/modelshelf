import AppKit

/// Web pages and bundled documents the app links to: the Help menu, the About panel, the setup
/// screen and Settings. App Review requires the privacy policy to be reachable from inside the app.
enum Links {
    static let privacy = URL(string: "https://thisbrain.ai/opensource/privacy.html#modelshelf")!
    static let support = URL(string: "https://thisbrain.ai/opensource/support.html#modelshelf")!
    static let source = URL(string: "https://github.com/ancientcomputing/modelshelf")!
    static let issues = URL(string: "https://github.com/ancientcomputing/modelshelf/issues")!
    static let sdk = URL(string: "https://github.com/ancientcomputing/locallm")!
    static let license = URL(string: "https://www.apache.org/licenses/LICENSE-2.0")!
    static let company = URL(string: "https://thisbrain.ai")!
    static let email = URL(string: "mailto:neuron@thisbrain.ai?subject=Model%20Shelf")!

    /// The third-party notices bundled in the app (packaging/Resources/Acknowledgements.txt).
    static var acknowledgements: URL? { Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt") }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    static func openAcknowledgements() {
        if let url = acknowledgements {
            NSWorkspace.shared.open(url)
        } else {
            open(URL(string: "https://github.com/ancientcomputing/modelshelf/blob/main/NOTICE")!)
        }
    }

    /// The standard About panel, with credits that say what the app is, who makes it, what it's
    /// built on and where to go next. Copyright comes from NSHumanReadableCopyright.
    @MainActor static func showAbout() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = 6
        let base: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: centered]

        let credits = NSMutableAttributedString()
        func text(_ s: String) { credits.append(NSAttributedString(string: s, attributes: base)) }
        func link(_ s: String, _ url: URL) {
            var a = base
            a[.link] = url
            credits.append(NSAttributedString(string: s, attributes: a))
        }

        text("Keeps the AI models you run locally organized between your Mac and an external drive.\n")
        text("Free and open source under the ")
        link("Apache License 2.0", license)
        text(". ")
        link("Source code on GitHub", source)
        text(".\n")
        text("Redownloads use the ")
        link("LocalLM SDK", sdk)
        text(" by ThisBrainAI, which includes MLX, swift-transformers and other open-source software. ")
        if let ack = acknowledgements { link("Acknowledgements", ack) } else { link("Acknowledgements", source) }
        text(".\n")
        link("Support", support)
        text("  ·  ")
        link("Privacy Policy", privacy)
        text("  ·  ")
        link("thisbrain.ai", company)

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
