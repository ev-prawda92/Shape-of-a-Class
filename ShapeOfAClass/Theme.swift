import SwiftUI
import UIKit

enum Theme {
    static let ground = Color(light: 0xF4EFEC, dark: 0x171114)
    static let surface = Color(light: 0xFFFFFF, dark: 0x201A1D)
    static let ink = Color(light: 0x2B2025, dark: 0xEEE4E7)
    static let inkSoft = Color(light: 0x8B7982, dark: 0x94838A)
    static let warm = Color(light: 0xB0700F, dark: 0xE0A63F)
    static let warmSoft = Color(light: 0xF6E9D3, dark: 0x2E2318)
    static let cool = Color(light: 0x2C6B66, dark: 0x63AAA3)
    static let plum = Color(light: 0x8A3B54, dark: 0xD08099)

    static func display(_ style: Font.TextStyle) -> Font { .system(style, design: .serif) }
    static let eyebrow = Font.system(.caption2, design: .monospaced).weight(.medium)
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

struct Eyebrow: View {
    let text: String
    var color: Color = Theme.inkSoft
    init(_ text: String, color: Color = Theme.inkSoft) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(Theme.eyebrow)
            .tracking(1.2)
            .foregroundStyle(color)
    }
}

struct Card<Inner: View>: View {
    @ViewBuilder var content: Inner
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
