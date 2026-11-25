import MapKit
import SwiftUI

struct RichMap: Codable, Hashable, Sendable {
    let title: String
    let latitude: Double
    let longitude: Double

    func validate() -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 256
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }

    /// Accept a place name and optional qualifiers, never an unrelated suggestion.
    static func matches(_ request: String, name: String, address: [String]) -> Bool {
        func words(_ text: String) -> Set<Substring> {
            Set(AssistantIntent.normalized(text).split { !$0.isLetter && !$0.isNumber })
                .subtracting(["city", "the", "of"])
        }
        let nameWords = words(name)
        let requested = words(request)
        return !requested.isEmpty && !requested.isDisjoint(with: nameWords)
            && requested.isSubset(of: words(([name] + address).joined(separator: " ")))
    }

    @MainActor static func lookUp(_ query: String) async -> AssistantReply {
        guard GenerativeUIIntegration.isEnabled else {
            return AssistantReply("Turn on Generative UI in Settings to see maps here.")
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let response = try? await MKLocalSearch(request: request).start(), !Task.isCancelled else {
            return AssistantReply("I couldn’t load a map for \(query). Please try again.")
        }
        let matches = response.mapItems.filter { item in
            let address = [item.placemark.locality, item.placemark.administrativeArea, item.placemark.country]
                .compactMap { $0 }
            return Self.matches(query, name: item.name ?? "", address: address)
        }
        guard let first = matches.first, let name = first.name else {
            return AssistantReply("I couldn’t match \(query). Try saying the city and country.")
        }
        let location = first.placemark.coordinate
        if matches.dropFirst().contains(where: { item in
            let other = item.placemark.coordinate
            return CLLocation(latitude: location.latitude, longitude: location.longitude)
                .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude)) > 25_000
        }) {
            return AssistantReply("I found more than one match for \(query). Try including the region or country.")
        }

        let title = ([name] + [first.placemark.administrativeArea, first.placemark.country].compactMap { $0 })
            .joined(separator: ", ")
        let map = RichMap(title: String(title.prefix(256)), latitude: location.latitude, longitude: location.longitude)
        return map.reply()
    }

    func reply() -> AssistantReply {
        let block = RichBlock(type: .map, id: "map", payload: .map(self))
        let surface = RichSurface(
            version: 2, id: "voice-map", title: title, fallback: "Map of \(title)", kind: .native, blocks: [block])
        guard surface.validate(), let data = try? JSONEncoder().encode(surface) else {
            return AssistantReply("I couldn’t display the map for \(title).")
        }
        return AssistantReply(
            "Here’s the map of \(title).",
            visual: "```herm-ui\n" + String(decoding: data, as: UTF8.self) + "\n```")
    }
}

struct RichMapView: View {
    let place: RichMap
    let interactive: Bool
    @Environment(\.richVoicePosition) private var voicePosition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var camera: MapCameraPosition

    init(place: RichMap, interactive: Bool) {
        self.place = place
        self.interactive = interactive
        _camera = State(initialValue: Self.position(for: place, zoom: 0))
    }

    var body: some View {
        Map(position: $camera, interactionModes: interactive ? .all : []) {
            Marker(place.title, coordinate: place.coordinate)
        }
        .onChange(of: place) { _, place in
            camera = Self.position(for: place, zoom: interactive ? 0 : voicePosition.zoom)
        }
        .onChange(of: voicePosition.zoom, initial: true) { old, zoom in
            guard !interactive else { return }
            let next = Self.position(for: place, zoom: zoom)
            if old == zoom || reduceMotion {
                camera = next
            } else {
                withAnimation(.easeOut(duration: 0.2)) { camera = next }
            }
        }
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Map of \(place.title)")
    }

    private static func position(for place: RichMap, zoom: Int) -> MapCameraPosition {
        let span = 16_000 * pow(0.5, Double(zoom))
        return .region(
            MKCoordinateRegion(center: place.coordinate, latitudinalMeters: span, longitudinalMeters: span))
    }
}
