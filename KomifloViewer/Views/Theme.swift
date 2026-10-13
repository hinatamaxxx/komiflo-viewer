import SwiftUI
import UIKit

enum Theme {
    static let background = Color(red: 0.05, green: 0.05, blue: 0.06)
    static let bar = Color(red: 0.09, green: 0.09, blue: 0.11)
    static let placeholder = Color(white: 0.18)
    /// 公式サイトのピンク（rgb 239, 66, 116）
    static let accent = Color(red: 239 / 255, green: 66 / 255, blue: 116 / 255)
    /// 公式サイトの棚の見出しの灰色（rgb 135, 135, 135）
    static let sectionTitle = Color(white: 135 / 255)
    static let star = Color(red: 1.0, green: 0.8, blue: 0.3)

    static let uiBackground = UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
}
