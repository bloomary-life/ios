import Foundation
import SafariServices
import UIKit

@MainActor
final class SafariAuthorizationPresenter: NSObject, AuthorizationPresenter, @preconcurrency SFSafariViewControllerDelegate {
    private var viewController: SFSafariViewController?
    private var continuation: CheckedContinuation<Void, Error>?

    func present(url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            guard let presenter = UIApplication.shared.topViewController() else {
                continuation.resume(throwing: LinkedInAuthError.missingWindow)
                return
            }
            let browser = SFSafariViewController(url: url)
            browser.delegate = self
            browser.preferredControlTintColor = AppStyle.uiInk
            self.viewController = browser
            self.continuation = continuation
            presenter.present(browser, animated: true)
        }
    }

    func complete(with url: URL) {
        dismissBrowser()
        if let continuation {
            self.continuation = nil
            continuation.resume()
        }
    }

    func cancel() {
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: LinkedInAuthError.cancelled)
        }
        dismissBrowser()
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        if let continuation {
            self.continuation = nil
            continuation.resume(throwing: LinkedInAuthError.cancelled)
        }
        viewController = nil
    }

    private func dismissBrowser() {
        viewController?.dismiss(animated: true)
        viewController = nil
    }
}

private extension UIApplication {
    func topViewController(
        from root: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
    ) -> UIViewController? {
        if let navigation = root as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = root as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        if let presented = root?.presentedViewController {
            return topViewController(from: presented)
        }
        return root
    }
}
