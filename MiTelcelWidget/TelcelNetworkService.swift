import Foundation

// MARK: - Operadores de Perú
enum PeruCarrier: String, CaseIterable, Codable {
    case claro = "Claro"
    case movistar = "Movistar"
    case entel = "Entel"
    case bitel = "Bitel"
    
    var brandColorHex: String {
        switch self {
        case .claro: return "#DA291C"    // Rojo Claro
        case .movistar: return "#019DF4" // Azul Movistar
        case .entel: return "#002EFF"    // Azul Entel
        case .bitel: return "#00A859"    // Verde/Turquesa Bitel
        }
    }
}

// MARK: - Modelo Unificado de Consumo para el Widget
struct CarrierUsageData: Codable {
    let carrier: PeruCarrier
    let phoneNumber: String
    let planName: String
    let usedGB: Double
    let totalGB: Double
    let freeSocialGB: Double?
    let balancePEN: Double?        // Saldo en Soles (S/)
    let expirationDate: String     // Fecha de corte o vencimiento
    let lastUpdated: Date
    
    var remainingGB: Double {
        max(0, totalGB - usedGB)
    }
    
    var usagePercentage: Double {
        guard totalGB > 0 else { return 0 }
        return min(1.0, usedGB / totalGB)
    }
}

// MARK: - Almacenamiento Compartido (App + Widget)
final class SharedStorage {
    // IMPORTANTE: Usa este mismo App Group en Xcode o cámbialo en ambos targets
    static let appGroupID = "group.com.srjw.miconsumoperu"
    
    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }
    
    static func saveCredentials(carrier: PeruCarrier, phone: String, passwordOrToken: String, isBearerToken: Bool) {
        defaults.set(carrier.rawValue, forKey: "carrier")
        defaults.set(phone, forKey: "phone")
        defaults.set(passwordOrToken, forKey: "secret")
        defaults.set(isBearerToken, forKey: "isBearerToken")
    }
    
    static func saveCachedUsage(_ data: CarrierUsageData) {
        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: "cachedUsage")
        }
    }
    
    static func loadCachedUsage() -> CarrierUsageData? {
        guard let data = defaults.data(forKey: "cachedUsage") else { return nil }
        return try? JSONDecoder().decode(CarrierUsageData.self, from: data)
    }
}

// MARK: - Servicio de Red Multimarca Perú
final class TelcelNetworkService {
    static let shared = TelcelNetworkService()
    
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
    
    // Endpoints base de las operadoras en Perú
    private func endpoint(for carrier: PeruCarrier) -> (loginURL: String, balanceURL: String, userAgent: String) {
        switch carrier {
        case .claro:
            return (
                loginURL: "https://miclaro.com.pe/api/v1/auth/login",
                balanceURL: "https://miclaro.com.pe/api/v1/postpaid/balance",
                userAgent: "MiClaroPe/14.2.0 (iPhone; iOS 17.5; Scale/3.00)"
            )
        case .movistar:
            return (
                loginURL: "https://api.movistar.com.pe/oauth/v2/token",
                balanceURL: "https://api.movistar.com.pe/mobile/v1/lines/balances",
                userAgent: "MiMovistarPe/11.8.0 (iOS; iPhone14,2)"
            )
        case .entel:
            return (
                loginURL: "https://api.entel.pe/auth/v1/otp/validate",
                balanceURL: "https://api.entel.pe/consumption/v1/summary",
                userAgent: "MiEntelPeru/6.14.0 (iPhone; iOS 17.5)"
            )
        case .bitel:
            return (
                loginURL: "https://mibitel.bitel.com.pe/api/v1/login",
                balanceURL: "https://mibitel.bitel.com.pe/api/v1/subscriber/AccountInfo",
                userAgent: "MiBitel/5.4.1 (iOS)"
            )
        }
    }
    
    func fetchUsage() async throws -> CarrierUsageData {
        let defaults = SharedStorage.defaults
        guard let carrierRaw = defaults.string(forKey: "carrier"),
              let carrier = PeruCarrier(rawValue: carrierRaw),
              let phone = defaults.string(forKey: "phone"),
              let secret = defaults.string(forKey: "secret"),
              !phone.isEmpty, !secret.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let isBearer = defaults.bool(forKey: "isBearerToken")
        let config = endpoint(for: carrier)
        
        // 1. Si el usuario ingresó un Token directo (ideal para Entel/Movistar con OTP)
        let token: String
        if isBearer {
            token = secret
        } else {
            token = try await authenticate(carrier: carrier, phone: phone, password: secret, urlString: config.loginURL, userAgent: config.userAgent)
        }
        
        // 2. Consultar el saldo de datos
        guard let url = URL(string: "\(config.balanceURL)?msisdn=51\(phone)") else {
            throw URLError(.badURL)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            // Si falla la red, cae al último dato guardado en caché para no dejar el widget en blanco
            if let cached = SharedStorage.loadCachedUsage() { return cached }
            throw URLError(.badServerResponse)
        }
        
        let parsed = try parseCarrierJSON(data: data, carrier: carrier, phone: phone)
        SharedStorage.saveCachedUsage(parsed)
        return parsed
    }
    
    private func authenticate(carrier: PeruCarrier, phone: String, password: String, urlString: String, userAgent: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        
        let body: [String: Any] = [
            "msisdn": phone,
            "countryCode": "51",
            "password": password
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, _) = try await session.data(for: request)
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = (json["access_token"] as? String) ?? (json["token"] as? String) ?? ((json["data"] as? [String: Any])?["token"] as? String) {
            return token
        }
        throw URLError(.userAuthenticationRequired)
    }
    
    // Parser flexible que normaliza las respuestas de Claro, Movistar, Entel y Bitel
    private func parseCarrierJSON(data: Data, carrier: PeruCarrier, phone: String) throws -> CarrierUsageData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        
        let payload = (json["data"] as? [String: Any]) ?? (json["response"] as? [String: Any]) ?? json
        
        // Conversión automática de MB a GB si la operadora devuelve valores en Megabytes (> 500)
        let rawUsed = (payload["usedData"] as? Double) ?? (payload["consumido"] as? Double) ?? 0.0
        let rawTotal = (payload["totalData"] as? Double) ?? (payload["total"] as? Double) ?? 1.0
        
        let usedGB = rawTotal > 500 ? (rawUsed / 1024.0) : rawUsed
        let totalGB = rawTotal > 500 ? (rawTotal / 1024.0) : rawTotal
        let planName = (payload["planName"] as? String) ?? (payload["nombrePlan"] as? String) ?? "Plan \(carrier.rawValue)"
        let balancePEN = (payload["balance"] as? Double) ?? (payload["saldoRecarga"] as? Double)
        let expiration = (payload["expirationDate"] as? String) ?? (payload["fechaCorte"] as? String) ?? "Ciclo mensual"
        
        return CarrierUsageData(
            carrier: carrier,
            phoneNumber: phone,
            planName: planName,
            usedGB: (usedGB * 100).rounded() / 100,
            totalGB: (totalGB * 100).rounded() / 100,
            freeSocialGB: payload["socialData"] as? Double,
            balancePEN: balancePEN,
            expirationDate: expiration,
            lastUpdated: Date()
        )
    }
}
