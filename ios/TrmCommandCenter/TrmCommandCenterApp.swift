import SwiftUI

/// trm's phone half: the Command Center, away from the desk.
///
/// The Mac panel answers "which of my agents needs me, and what do I say
/// back". That question doesn't stop mattering when you get up — an agent
/// that asked something at 11pm is blocked until someone answers, and the
/// answer is usually a sentence. So this shows the same board and can type
/// into the same panes, and does nothing else.
@main
struct TrmCommandCenterApp: App {
    @StateObject private var client = CommandCenterClient()

    var body: some Scene {
        WindowGroup {
            BoardView()
                .environmentObject(client)
                .onAppear { client.connect() }
        }
    }
}
