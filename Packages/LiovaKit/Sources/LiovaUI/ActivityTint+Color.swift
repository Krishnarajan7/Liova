import LiovaPluginKit
import SwiftUI

extension ActivityTint {
    var color: Color {
        switch self {
        case .accent: .accentColor
        case .green: .green
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}
