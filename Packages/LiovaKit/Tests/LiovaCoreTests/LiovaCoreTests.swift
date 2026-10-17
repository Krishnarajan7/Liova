import LiovaCore
import LiovaPluginKit
import Testing

@Test func coreSpeaksCurrentPluginAPI() {
    #expect(LiovaCore.pluginAPIVersion == LiovaPluginKit.apiVersion)
}
