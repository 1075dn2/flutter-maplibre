#if MAPLIBRE_EXPERIMENTAL_SCOPED_HEADERS
import Foundation
import MapLibre

/// Disabled unless the app supplies both explicit opt-in and approved headers.
/// Install before either map views or MLNOfflineStorage first use.
final class ScopedRequestNetwork: NSObject, MLNNetworkConfigurationDelegate, URLSessionTaskDelegate {
    private static var retained: ScopedRequestNetwork?
    private let policy: ScopedRequestPolicy
    private var session: URLSession!

    private init(policy: ScopedRequestPolicy, configuration: URLSessionConfiguration) {
        self.policy = policy
        super.init()
        // Do not use global additional headers, trust callbacks, background
        // sessions, or NSURLSessionDataDelegate (unsupported by MapLibre6.21).
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    static func installIfConfigured(bundle: Bundle = .main) {
        guard Thread.isMainThread, retained == nil,
              bundle.object(forInfoDictionaryKey: "MapLibreScopedRequestHeadersEnabled") as? Bool == true,
              let raw = bundle.object(forInfoDictionaryKey: "MapLibreScopedRequestHeaders") as? [String: Any],
              let policy = ScopedRequestPolicy(configuration: raw) else { return }
        let configuration = MLNNetworkConfiguration.sharedManager
        // Never replace another component's delegate.
        guard configuration.delegate == nil else { return }
        let instance = ScopedRequestNetwork(policy: policy, configuration: configuration.sessionConfiguration)
        retained = instance // The SDK delegate is weak.
        configuration.delegate = instance
    }

    @objc(willSendRequest:)
    func scopedRequest(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
        return (policy.apply(to: request as URLRequest) as NSURLRequest).mutableCopy() as! NSMutableURLRequest
    }

    @objc(sessionForNetworkConfiguration:)
    func configuredSession(_ configuration: MLNNetworkConfiguration) -> URLSession {
        return session
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(policy.redirect(original: task.originalRequest,
                                          current: task.currentRequest, proposed: request))
    }
}

#endif
