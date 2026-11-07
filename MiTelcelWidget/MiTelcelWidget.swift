import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: CarrierUsageData
}

struct Provider: TimelineProvider {
    private let placeholderUsage = CarrierUsageData(
        carrier: .claro,
        phoneNumber: "987654321",
        planName: "Plan Postpago Perú",
        usedGB: 12.5,
        totalGB: 40.0,
        freeSocialGB: 5.0,
        balancePEN: 10.0,
        expirationDate: "Corte: Día 15",
        lastUpdated: Date()
    )
    
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), usage: placeholderUsage)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> ()) {
        let data = SharedStorage.loadCachedUsage() ?? placeholderUsage
        completion(UsageEntry(date: Date(), usage: data))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> ()) {
        Task {
            let usageData: CarrierUsageData
            do {
                usageData = try await TelcelNetworkService.shared.fetchUsage()
            } catch {
                usageData = SharedStorage.loadCachedUsage() ?? placeholderUsage
            }
            
            let entry = UsageEntry(date: Date(), usage: usageData)
            // Refrescar cada 2 horas para ahorrar batería y evitar bloqueos de IP
            let nextUpdate = Calendar.current.date(byAdding: .hour, value: 2, to: Date())!
            let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
            completion(timeline)
        }
    }
}

struct MiTelcelWidgetEntryView : View {
    var entry: Provider.Entry
    
    var brandColor: Color {
        switch entry.usage.carrier {
        case .claro: return .red
        case .movistar: return .cyan
        case .entel: return .blue
        case .bitel: return .green
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.usage.carrier.rawValue.uppercased())
                    .font(.caption2)
                    .fontWeight(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(brandColor.opacity(0.2))
                    .foregroundStyle(brandColor)
                    .clipShape(Capsule())
                
                Spacer()
                
                if let saldo = entry.usage.balancePEN {
                    Text(String(format: "S/ %.2f", saldo))
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                }
            }
            
            Spacer(minLength: 2)
            
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", entry.usage.remainingGB))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .widgetAccentable()
                Text("GB libres")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            ProgressView(value: entry.usage.usagePercentage)
                .tint(brandColor)
            
            HStack {
                Text("De \(Int(entry.usage.totalGB)) GB")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.usage.expirationDate)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

@main
struct MiTelcelWidget: Widget {
    let kind: String = "MiTelcelWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            MiTelcelWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Mi Consumo Perú")
        .description("Monitorea tus gigas y saldo de Claro, Movistar, Entel y Bitel.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
