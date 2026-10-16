import SwiftUI

/// Access copy from `docs/product/tiers.md` "Copy — lapsed banners".
enum AccessBannerCopy {
    static let publishNeedsPlan = "Publishing needs an active plan."

    /// Rows 1–2: the reason the archive is read-only, so "trial ended" never reads as "subscription ended".
    static func lapsed(subscriptionSource: String?, endedOn date: Date?) -> String {
        let grant = ["apple", "paddle"].contains(subscriptionSource ?? "") ? "Your subscription" : "Your 14-day trial"
        let ended = date.map { " on \(formatted($0))" } ?? ""
        return "\(grant) ended\(ended). Your drafts are read-only."
    }

    /// Row 6: posts scheduled before the lapse still fire.
    static func scheduledStillPublish(lapsedOn date: Date) -> String {
        "Posts you scheduled before \(formatted(date)) will still publish."
    }

    static func formatted(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Persistent, non-dismissible access banner: reason, what is locked, one action.
struct AccessBanner: View {
    let message: String
    var detail: String?
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppStyle.ink)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(AppStyle.muted)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppStyle.coral)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(AppStyle.coral.opacity(0.1))
        .background(AppStyle.paper)
    }
}
