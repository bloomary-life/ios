import AVFoundation
import SwiftUI

struct PostSuccessView: View {
    @Environment(\.dismiss) private var dismiss

    let onViewOnLinkedIn: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Posted to LinkedIn")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(AppStyle.ink)

            Text("Your post is live.")
                .font(.subheadline)
                .foregroundStyle(AppStyle.muted)

            VStack(spacing: 10) {
                Button("View on LinkedIn") {
                    onViewOnLinkedIn()
                }
                .buttonStyle(SecondaryButtonStyle())

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding()
        .background(AppStyle.paper)
        .onAppear {
            AudioServicesPlaySystemSound(1004)
        }
    }
}
