import SwiftUI

/// Minimal Preferences (⌘,) surface. One toggle today; the receipt policy
/// is applied per request, so changes take effect without a restart.
struct SettingsView: View {
    @AppStorage("suppressDMReadReceipts") private var suppressDMReadReceipts = true

    var body: some View {
        Form {
            Toggle("Don't send read receipts in direct messages", isOn: $suppressDMReadReceipts)
        }
        .padding(16)
        .frame(width: 380)
    }
}
