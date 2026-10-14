import AppKit
import DiscCore

/// The standard About panel, with credits linking to bluepill.ca.
enum AboutPanel {
    static let website = URL(string: "https://bluepill.ca")!

    @MainActor
    static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
        NSApp.activate()
    }

    private static func credits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: center,
        ]

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: "bluepill.ca", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
            .link: website,
            .paragraphStyle: center,
        ]))
        text.append(NSAttributedString(string: "\nArchives DVDs as lossless MKV files, reading damaged discs with care.\n", attributes: body))

        let v = dc.libraryVersions()
        text.append(NSAttributedString(
            string: "Built with libdvdread \(String(v.libdvdread)), libdvdcss \(String(v.libdvdcss)) and FFmpeg (libavformat \(String(v.libavformat))).\n",
            attributes: body))
        text.append(NSAttributedString(
            string: "This product uses the TMDB API but is not endorsed or certified by TMDB.",
            attributes: body))
        return text
    }
}
