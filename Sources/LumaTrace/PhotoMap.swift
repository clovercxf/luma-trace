import SwiftUI
import MapKit
import AppKit

struct PhotoLocation: Identifiable {
    var id: String
    var latitude: Double
    var longitude: Double
    var items: [MediaItem]
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

enum PhotoLocations {
    static func valid(_ item: MediaItem) -> Bool {
        guard let a = item.latitude, let b = item.longitude else { return false }
        return a.isFinite && b.isFinite && (-90...90).contains(a) && (-180...180).contains(b)
    }

    // Coarser grids group nearby photos when zoomed out; finer grids reveal
    // progressively more precise clusters as the user zooms in.
    static func groups(_ items: [MediaItem], zoomLevel: Double = 18) -> [PhotoLocation] {
        let decimals = min(5, max(0, Int(floor(zoomLevel / 3)) - 1))
        let factor = pow(10.0, Double(decimals))
        let groups = Dictionary(grouping: items.filter(valid)) { item in
            let lat = (item.latitude! * factor).rounded() / factor
            let lon = (item.longitude! * factor).rounded() / factor
            return String(format: "%.5f,%.5f", locale: Locale(identifier: "en_US_POSIX"), lat, lon)
        }
        return groups.map { key, values in
            let centerLat = values.compactMap(\.latitude).reduce(0, +) / Double(values.count)
            let centerLon = values.compactMap(\.longitude).reduce(0, +) / Double(values.count)
            return PhotoLocation(id: key, latitude: centerLat, longitude: centerLon, items: values.sorted { $0.date > $1.date })
        }.sorted { $0.id < $1.id }
    }
}

private final class LumaTraceOSMTileOverlay: MKTileOverlay {
    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        guard let template = urlTemplate else { result(nil, URLError(.badURL)); return }
        let urlString = template
            .replacingOccurrences(of: "{z}", with: String(path.z))
            .replacingOccurrences(of: "{x}", with: String(path.x))
            .replacingOccurrences(of: "{y}", with: String(path.y))
        guard let url = URL(string: urlString) else { result(nil, URLError(.badURL)); return }
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 20)
        request.setValue("LumaTrace/0.4.5 (macOS photo library)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                result(nil, error ?? URLError(.badServerResponse)); return
            }
            result(data, nil)
        }.resume()
    }
}

private final class PhotoCountAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let location: PhotoLocation
    init(location: PhotoLocation) {
        self.location = location
        coordinate = location.coordinate
        title = String(location.items.count)
    }
}

private struct OpenStreetMapView: NSViewRepresentable {
    var items: [MediaItem]
    var fitToken: UUID
    var onSelect: (PhotoLocation) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        let tiles = LumaTraceOSMTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        tiles.canReplaceMapContent = true
        map.addOverlay(tiles, level: .aboveLabels)
        context.coordinator.map = map
        context.coordinator.update(items: items, map: map)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(items: items, map: map)
        if context.coordinator.fitToken != fitToken {
            context.coordinator.fitToken = fitToken
            context.coordinator.fitAll(map: map)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        var onSelect: (PhotoLocation) -> Void
        private var zoomLevel = 3.0
        private var currentSignature = ""
        private var items: [MediaItem] = []
        var fitToken = UUID()

        init(onSelect: @escaping (PhotoLocation) -> Void) { self.onSelect = onSelect }

        func update(items: [MediaItem], map: MKMapView) {
            self.items = items
            let groups = PhotoLocations.groups(items, zoomLevel: zoomLevel)
            let signature = groups.map { "\($0.id):\($0.items.count)" }.joined(separator: "|")
            if groups.isEmpty {
                if signature != currentSignature {
                    map.removeAnnotations(map.annotations)
                    currentSignature = signature
                }
                if map.region.span.longitudeDelta >= 360 { showWorld(map: map, animated: false) }
                return
            }
            guard signature != currentSignature else { return }
            currentSignature = signature
            map.removeAnnotations(map.annotations)
            map.addAnnotations(groups.map(PhotoCountAnnotation.init(location:)))
            if map.region.span.longitudeDelta >= 360 {
                fitAll(map: map, groups: groups)
            }
        }

        func fitAll(map: MKMapView, groups: [PhotoLocation]? = nil) {
            let locations = groups ?? PhotoLocations.groups(items, zoomLevel: zoomLevel)
            guard !locations.isEmpty else { showWorld(map: map, animated: true); return }
            map.setRegion(MKCoordinateRegion(points: locations.map(\.coordinate)), animated: true)
        }

        private func showWorld(map: MKMapView, animated: Bool) {
            let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 20, longitude: 0), span: MKCoordinateSpan(latitudeDelta: 120, longitudeDelta: 300))
            map.setRegion(region, animated: animated)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            zoomLevel = log2(360 / max(mapView.region.span.longitudeDelta, 0.000001))
            currentSignature = "" // force annotations to re-cluster at the new zoom
            if let map { update(items: items, map: map) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let photo = annotation as? PhotoCountAnnotation else { return nil }
            let identifier = "photo-count"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = photo
            view.markerTintColor = NSColor(calibratedRed: 0.14, green: 0.42, blue: 0.99, alpha: 1)
            view.glyphText = photo.title
            view.glyphImage = nil
            view.clusteringIdentifier = nil
            view.displayPriority = .required
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let photo = view.annotation as? PhotoCountAnnotation else { return }
            onSelect(photo.location)
            mapView.deselectAnnotation(photo, animated: false)
        }
    }
}

private extension MKCoordinateRegion {
    init(points: [CLLocationCoordinate2D]) {
        guard let first = points.first else { self = MKCoordinateRegion(); return }
        let minLat = points.map(\.latitude).min() ?? first.latitude
        let maxLat = points.map(\.latitude).max() ?? first.latitude
        let minLon = points.map(\.longitude).min() ?? first.longitude
        let maxLon = points.map(\.longitude).max() ?? first.longitude
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.35, 0.03), longitudeDelta: max((maxLon - minLon) * 1.35, 0.03))
        self.init(center: center, span: span)
    }
}

struct PhotoMapView: View {
    @ObservedObject var store: LibraryStore
    @StoredState private var selected: PhotoLocation?
    @StoredState private var fitToken = UUID()
    private var located: Int { store.visible.filter(PhotoLocations.valid).count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tr("\(located) 项有定位 · \(store.displayItems.count - located) 项无定位")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(tr("显示全部位置")) { fitToken = UUID() }
            }.padding(12)
            OpenStreetMapView(items: store.visible, fitToken: fitToken) { selected = $0 }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 4) {
                Text(tr("地图 © OpenStreetMap 贡献者"))
                Link(tr("报告地图问题"), destination: URL(string: "https://www.openstreetmap.org/fixthemap")!)
                Text("· " + tr("地图需要网络；照片和 GPS 不会上传。"))
            }.font(.caption2).foregroundStyle(.secondary).padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $selected) { group in
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(tr("此位置的影像") + " · \(group.items.count)").font(.headline); Spacer(); Button(tr("完成")) { selected = nil } }
                Text(String(format: "%.5f, %.5f", group.latitude, group.longitude)).font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(group.items) { item in
                            MediaCard(item: item, compact: true, open: { MediaBrowserWindowController.shared.show(store: store, request: item, items: group.items) }) { store.selectedID = item.id }
                        }
                    }
                }
            }.padding(20).frame(width: 700, height: 500)
        }
    }
}
