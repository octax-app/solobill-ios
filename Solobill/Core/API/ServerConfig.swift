import Foundation

/// Which server the app talks to. Release builds always use the URL set in `project.yml`.
///
/// Debug builds can override it, from the login screen or with the launch argument
/// `-serverURL http://localhost:3101`, so a build on a real phone can reach a real server.
enum ServerConfig {
    private static let overrideKey = "serverURL"

    static var defaultURL: String {
        Bundle.main.object(forInfoDictionaryKey: "API_BASE_URL") as? String ?? "https://inv.octax.dev"
    }

    static var baseURL: URL {
        #if DEBUG
        if let text = UserDefaults.standard.string(forKey: overrideKey), let url = URL(string: text) {
            return url
        }
        #endif
        guard let url = URL(string: defaultURL) else { preconditionFailure("API_BASE_URL is not a URL") }
        return url
    }

    #if DEBUG
    static func setOverride(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == defaultURL {
            UserDefaults.standard.removeObject(forKey: overrideKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: overrideKey)
        }
    }
    #endif
}
