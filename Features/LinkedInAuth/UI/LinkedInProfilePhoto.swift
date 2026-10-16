import SwiftUI
import UIKit

struct LinkedInProfilePhoto: View {
    let pictureURL: String?
    let size: CGFloat
    @State private var uiImage: UIImage?

    var body: some View {
        ZStack {
            fallback

            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: pictureURL) {
            await loadPhoto()
        }
    }

    @MainActor
    private func loadPhoto() async {
        guard let pictureURL, let url = URL(string: pictureURL) else {
            uiImage = nil
            return
        }

        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
        request.setValue("Bloomary/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                uiImage = nil
                return
            }
            uiImage = image
        } catch {
            uiImage = nil
        }
    }

    private var fallback: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.039, green: 0.400, blue: 0.761))
            Text("in")
                .font(.system(size: max(size * 0.42, 10), weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
