import SwiftUI

extension EnvironmentValues {
    @Entry var api = APIClient()
}

@main
struct SolobillApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: Session
    @State private var push: PushCenter
    private let api: APIClient

    init() {
        let api = APIClient()
        self.api = api
        _session = State(initialValue: Session(api: api))
        _push = State(initialValue: PushCenter(api: api))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .environment(push)
                .environment(\.api, api)
        }
    }
}
