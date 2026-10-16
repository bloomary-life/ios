import Foundation

enum BackendEnvironment: String, CaseIterable {
    case production
    case test

    var displayName: String {
        switch self {
        case .production: return "PROD"
        case .test: return "TEST"
        }
    }

    private static let userDefaultsKey = "backend_environment"

    static var selected: BackendEnvironment {
        get {
            UserDefaults.standard.string(forKey: userDefaultsKey)
                .flatMap(BackendEnvironment.init) ?? .production
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey)
        }
    }
}

struct AppConfiguration: Decodable {
    static let simulatorAPIBaseURL = URL(string: "https://api.bloomary.life") ?? URL(fileURLWithPath: "/")
    static let fallbackTestBaseURL = URL(string: "https://api-stage.bloomary.life") ?? URL(fileURLWithPath: "/")

    struct API: Decodable {
        let baseURL: URL
        let testBaseURL: URL

        private enum CodingKeys: String, CodingKey {
            case baseURL
            case testBaseURL
        }

        init(baseURL: URL, testBaseURL: URL) {
            self.baseURL = baseURL
            self.testBaseURL = testBaseURL
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let baseURLString = try container.decode(String.self, forKey: .baseURL)
            guard let baseURL = URL(string: baseURLString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .baseURL,
                    in: container,
                    debugDescription: "Invalid baseURL"
                )
            }
            self.baseURL = baseURL
            let testBaseURLString = try container.decodeIfPresent(String.self, forKey: .testBaseURL)
            guard let testBaseURL = URL(string: testBaseURLString ?? Self.fallbackTestBaseURLString) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .testBaseURL,
                    in: container,
                    debugDescription: "Invalid testBaseURL"
                )
            }
            self.testBaseURL = testBaseURL
        }

        private static let fallbackTestBaseURLString = "https://api-test.bloomary.life"
    }

    struct LinkedIn: Decodable {
        let callbackURLScheme: String
    }

    struct Storage: Decodable {
        let draftsKey: String
        let linkedInTokenKey: String
    }

    struct Scheduling: Decodable {
        let maxAheadDays: Int

        static let weekdayPostTimes = ["10:00–12:00", "09:00–11:00", "10:00–12:00", "09:00–11:00", "10:00–12:00", "09:00–10:00", "10:00–12:00"]

        static func defaultScheduleDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            let weekday = calendar.component(.weekday, from: tomorrow) - 1
            let hour = Int(weekdayPostTimes[weekday].prefix(2))!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: tomorrow)!
        }

        static let minimumLeadTime: TimeInterval = 5 * 60
        static let `default` = Scheduling(maxAheadDays: 31)
    }

    struct Observability: Decodable {
        let sentryDSN: String
        let sentryEnvironment: String
        let sentryTracesSampleRate: Double
        let telemetryDeckAppID: String
        let telemetryDeckNamespace: String

        static let disabled = Observability(
            sentryDSN: "",
            sentryEnvironment: "production",
            sentryTracesSampleRate: 0.1,
            telemetryDeckAppID: "",
            telemetryDeckNamespace: ""
        )
    }

    let api: API
    let linkedIn: LinkedIn
    let storage: Storage
    let scheduling: Scheduling
    let observability: Observability

    private enum CodingKeys: String, CodingKey {
        case api
        case linkedIn
        case storage
        case scheduling
        case observability
    }

    init(api: API, linkedIn: LinkedIn, storage: Storage, scheduling: Scheduling, observability: Observability) {
        self.api = api
        self.linkedIn = linkedIn
        self.storage = storage
        self.scheduling = scheduling
        self.observability = observability
    }

    var activeEnvironment: BackendEnvironment {
        api.baseURL == api.testBaseURL ? .test : .production
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        api = try container.decode(API.self, forKey: .api)
        linkedIn = try container.decode(LinkedIn.self, forKey: .linkedIn)
        storage = try container.decode(Storage.self, forKey: .storage)
        scheduling = try container.decodeIfPresent(Scheduling.self, forKey: .scheduling) ?? .default
        observability = try container.decodeIfPresent(Observability.self, forKey: .observability) ?? .disabled
    }

    static let fallback = AppConfiguration(
        api: API(baseURL: URL(string: "https://api.bloomary.life") ?? URL(fileURLWithPath: "/"),
                 testBaseURL: fallbackTestBaseURL),
        linkedIn: LinkedIn(callbackURLScheme: "bloomary"),
        storage: Storage(draftsKey: "bloomary_drafts", linkedInTokenKey: "bloomary_linkedin_token"),
        scheduling: .default,
        observability: .disabled
    )

    static func load(bundle: Bundle = .main) -> AppConfiguration {
        let configuration: AppConfiguration
        guard let url = bundle.url(forResource: "AppConfiguration", withExtension: "plist") else {
            configuration = fallback
            return configuration.applyingRuntimeOverrides()
        }
        do {
            let data = try Data(contentsOf: url)
            configuration = try PropertyListDecoder().decode(AppConfiguration.self, from: data)
        } catch {
            configuration = fallback
        }
        return configuration.applyingRuntimeOverrides()
    }

    private func applyingRuntimeOverrides() -> AppConfiguration {
        let environment = BackendEnvironment.selected
        let baseURL: URL
        switch environment {
        case .test:
            baseURL = api.testBaseURL
        case .production:
            #if targetEnvironment(simulator)
            baseURL = Self.simulatorAPIBaseURL
            #else
            baseURL = api.baseURL
            #endif
        }
        return AppConfiguration(
            api: API(baseURL: baseURL, testBaseURL: api.testBaseURL),
            linkedIn: linkedIn,
            storage: Storage(draftsKey: storage.draftsKey + "." + (baseURL.host ?? environment.rawValue),
                             linkedInTokenKey: storage.linkedInTokenKey + "." + (baseURL.host ?? environment.rawValue)),
            scheduling: scheduling,
            observability: Observability(
                sentryDSN: observability.sentryDSN,
                sentryEnvironment: environment == .test ? "stage" : "production",
                sentryTracesSampleRate: observability.sentryTracesSampleRate,
                telemetryDeckAppID: environment == .test ? "" : observability.telemetryDeckAppID,
                telemetryDeckNamespace: observability.telemetryDeckNamespace
            )
        )
    }
}
