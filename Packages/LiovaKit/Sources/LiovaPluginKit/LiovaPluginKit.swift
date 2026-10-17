/// Public SDK surface shared by Liova and its plugins.
///
/// This module must stay dependency-free: plugins compile against it alone.
public enum LiovaPluginKit {
    /// Version of the plugin API. Bump on any breaking change to models or the wire format.
    public static let apiVersion = 1
}
