import SwiftUI
import WidgetKit

@main
struct MiTelcelApp: App {
    var body: some Scene {
        WindowGroup {
            PeruConfigView()
        }
    }
}

struct PeruConfigView: View {
    @State private var selectedCarrier: PeruCarrier = .claro
    @State private var phoneNumber: String = ""
    @State private var secret: String = ""
    @State private var isBearerToken: Bool = false
    @State private var statusMessage: String = ""
    @State private var isLoading: Bool = false
    
    var isValidPeruPhone: Bool {
        let trimmed = phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count == 9 && trimmed.first == "9" && trimmed.allSatisfy(\.isNumber)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Operador en Perú (+51)") {
                    Picker("Operadora", selection: $selectedCarrier) {
                        ForEach(PeruCarrier.allCases, id: \.self) { carrier in
                            Text(carrier.rawValue).tag(carrier)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    HStack {
                        Text("+51")
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        TextField("987654321 (9 dígitos)", text: $phoneNumber)
                            .keyboardType(.numberPad)
                    }
                }
                
                Section(header: Text("Autenticación"), footer: Text("En Entel y Movistar Perú se recomienda activar 'Usar Token Bearer' si tu línea inicia sesión solo con código SMS.")) {
                    Toggle("Usar Token Bearer (OTP / Sesión)", isOn: $isBearerToken)
                    
                    SecureField(isBearerToken ? "Pega tu Bearer Token aquí" : "Contraseña de Mi \(selectedCarrier.rawValue)", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                
                Section {
                    Button(action: saveAndSync) {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text("Guardar y Actualizar Widget")
                                    .fontWeight(.bold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!isValidPeruPhone || secret.isEmpty || isLoading)
                    
                    Button("Cargar Datos de Prueba (Probar Diseño)") {
                        loadMockData()
                    }
                    .foregroundStyle(.orange)
                }
                
                if !statusMessage.isEmpty {
                    Section("Estado") {
                        Text(statusMessage)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Mi Consumo Perú 🇵🇪")
            .onAppear(perform: loadSavedSettings)
        }
    }
    
    private func loadSavedSettings() {
        let d = SharedStorage.defaults
        if let raw = d.string(forKey: "carrier"), let c = PeruCarrier(rawValue: raw) {
            selectedCarrier = c
        }
        phoneNumber = d.string(forKey: "phone") ?? ""
        secret = d.string(forKey: "secret") ?? ""
        isBearerToken = d.bool(forKey: "isBearerToken")
    }
    
    private func saveAndSync() {
        isLoading = true
        statusMessage = "Sincronizando con \(selectedCarrier.rawValue) Perú..."
        SharedStorage.saveCredentials(carrier: selectedCarrier, phone: phoneNumber, passwordOrToken: secret, isBearerToken: isBearerToken)
        
        Task {
            do {
                _ = try await TelcelNetworkService.shared.fetchUsage()
                await MainActor.run {
                    WidgetCenter.shared.reloadAllTimelines()
                    statusMessage = "¡Sincronizado con éxito! Revisa tu Widget en la pantalla de inicio."
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Guardado en caché. Error de API: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
    
    private func loadMockData() {
        let sample = CarrierUsageData(
            carrier: selectedCarrier,
            phoneNumber: isValidPeruPhone ? phoneNumber : "999888777",
            planName: "Max Ilimitado S/ 69.90",
            usedGB: 18.4,
            totalGB: 45.0,
            freeSocialGB: 10.0,
            balancePEN: 15.50,
            expirationDate: "Renueva el 25 Nov",
            lastUpdated: Date()
        )
        SharedStorage.saveCachedUsage(sample)
        WidgetCenter.shared.reloadAllTimelines()
        statusMessage = "Datos de prueba de \(selectedCarrier.rawValue) enviados al Widget."
    }
}
