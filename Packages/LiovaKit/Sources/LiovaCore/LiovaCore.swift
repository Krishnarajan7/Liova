import LiovaPluginKit

/// Core services: activity engine, display manager, scheduler.
///
/// No SwiftUI here. Core decides *what* the notch shows; LiovaUI decides *how*.
public enum LiovaCore {
    /// Plugin API version this core speaks.
    public static let pluginAPIVersion = LiovaPluginKit.apiVersion
}
