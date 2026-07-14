import SwiftUI
import MapKit

/// Native twin of the web `trailMap` block (TrailMapBlock.tsx): a GPS shift
/// trail — an array of `{lat,lng,timestamp}` on row 0 of a bound query —
/// drawn as a path with optional start/end markers.
///
/// PRESENTATION DIVERGENCE (deliberate, per the native-port doctrine — prefer
/// a real native control over a pixel port): the web renders a **Google Static
/// Maps PNG**, so it needs an `apiKey`, caps the path at 100 points, and shows
/// a flat image. The native twin uses **MapKit** (`MKMapView` + `MKPolyline`),
/// which needs no API key and no point cap and gives a real pan/zoom map. So:
///   • `apiKey` is ACCEPTED but UNUSED — MapKit requires none, and the web's
///     "set an API key" error state is therefore dropped.
///   • `downsample`/the 100-point cap is dropped — MapKit draws the full path.
///   • `height` is honoured as the map's frame height (the web's 640px cap was
///     a Static Maps constraint and does not apply).
/// SEMANTICS MIRRORED EXACTLY: the bound query → row 0 → `pointsColumn`
/// extraction (`extractPoints`, ported function-for-function incl. the
/// defensive JSON-string parse and finite lat/lng filter), the placeholder
/// state strings, and `strokeColor`/`strokeWeight`/`showMarkers`.
struct CmsTrailMapBlockView: View {
    let block: CmsBlock
    @EnvironmentObject var runtime: CmsRuntime

    // MARK: - Props

    private var querySlug: String { block.props.string("querySlug") ?? "" }
    private var pointsColumn: String { block.props.string("pointsColumn") ?? "data" }
    /// Web `strokeWeight > 0 ? strokeWeight : 3`.
    private var strokeWeight: CGFloat {
        let w = CGFloat(block.props.double("strokeWeight") ?? 3)
        return w > 0 ? w : 3
    }
    private var showMarkers: Bool { block.props.bool("showMarkers") ?? true }
    /// Authored path colour — resolved as a theme token or CSS literal, else
    /// the web default `#8B0000` (dark red).
    private var strokeColor: Color {
        runtime.color(block.props.string("strokeColor")) ?? Color(red: 139 / 255, green: 0, blue: 0)
    }
    /// Frame height (web default 400, floored so the map is usable). No 640
    /// cap — that was a Static Maps limit, not a MapKit one.
    private var height: CGFloat {
        max(CGFloat(block.props.double("height") ?? 400), 120)
    }

    // MARK: - Body

    var body: some View {
        content
            .onAppear { if !querySlug.isEmpty { runtime.ensureLoaded(querySlug) } }
    }

    @ViewBuilder
    private var content: some View {
        if querySlug.isEmpty {
            placeholder("Bind this block to a trail query in the settings.")
        } else {
            switch runtime.state(for: querySlug) {
            case .error(let message):
                placeholder("Query error: \(message)", error: true)
            case .idle, .loading, .waiting:
                // Web collapses idle/waiting/loading into one prompt.
                placeholder("Select a shift to load its trail…")
            case .ok(let result):
                let points = Self.extractPoints(result.rows.first?[pointsColumn])
                if points.isEmpty {
                    placeholder("No location trail recorded for this shift.")
                } else {
                    CmsTrailMapView(
                        points: points,
                        strokeColor: strokeColor,
                        strokeWeight: strokeWeight,
                        showMarkers: showMarkers
                    )
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .cmsInspectorID("Cms.trailMap.map")
                }
            }
        }
    }

    private func placeholder(_ text: String, error: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(error ? .red : .secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 160)
            .padding(16)
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                    )
                    .foregroundColor(error ? Color.red.opacity(0.6) : Color.secondary.opacity(0.4))
            )
            .cmsInspectorID("Cms.trailMap.placeholder")
    }

    // MARK: - Points extraction (ported from TrailMapBlock.tsx `extractPoints`)

    struct LatLng: Equatable {
        let lat: Double
        let lng: Double
    }

    /// Pull `{lat,lng}` pairs out of the points column — an array of objects,
    /// or a JSON string of same (Firestore decode yields real objects, but be
    /// defensive against a stringified column). Faithful port: `Number(...)`
    /// coercion (numbers and numeric strings) + `Number.isFinite` filter.
    static func extractPoints(_ raw: CmsJSON?) -> [LatLng] {
        var value = raw ?? .null
        if case .string(let s) = value {
            guard let data = s.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(CmsJSON.self, from: data) else {
                return []
            }
            value = decoded
        }
        guard case .array(let items) = value else { return [] }
        var pts: [LatLng] = []
        for item in items {
            guard case .object(let obj) = item else { continue }
            guard let lat = coerceNumber(obj["lat"]), let lng = coerceNumber(obj["lng"]),
                  lat.isFinite, lng.isFinite else { continue }
            pts.append(LatLng(lat: lat, lng: lng))
        }
        return pts
    }

    /// Mirror JS `Number(x)` for the shapes that appear in trail rows: a real
    /// number, or a numeric string. Anything else → nil (skipped by the finite
    /// filter), matching the web where a non-numeric value yields NaN.
    private static func coerceNumber(_ j: CmsJSON?) -> Double? {
        switch j {
        case .number(let n): return n
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }
}

// MARK: - MapKit polyline map (cross-platform representable)

/// An endpoint marker for the trail (start = green "S", end = red "E").
private final class CmsTrailEndpoint: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let isStart: Bool
    init(coordinate: CLLocationCoordinate2D, isStart: Bool) {
        self.coordinate = coordinate
        self.isStart = isStart
    }
}

private final class CmsTrailMapCoordinator: NSObject, MKMapViewDelegate {
    var strokeColor: Color
    var strokeWeight: CGFloat
    /// Fingerprint of the drawn path, so we only re-fit the visible region
    /// when the trail actually changes (not on every SwiftUI update — that
    /// would fight the user's pan/zoom).
    var lastKey: String = ""

    init(strokeColor: Color, strokeWeight: CGFloat) {
        self.strokeColor = strokeColor
        self.strokeWeight = strokeWeight
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else {
            return MKOverlayRenderer(overlay: overlay)
        }
        let renderer = MKPolylineRenderer(polyline: polyline)
        #if os(iOS)
        renderer.strokeColor = UIColor(strokeColor)
        #elseif os(macOS)
        renderer.strokeColor = NSColor(strokeColor)
        #endif
        renderer.lineWidth = strokeWeight
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let endpoint = annotation as? CmsTrailEndpoint else { return nil }
        let id = "cmsTrailEndpoint"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation
        view.glyphText = endpoint.isStart ? "S" : "E"
        #if os(iOS)
        view.markerTintColor = endpoint.isStart ? .systemGreen : .systemRed
        #elseif os(macOS)
        view.markerTintColor = endpoint.isStart ? .systemGreen : .systemRed
        #endif
        return view
    }
}

/// `MKMapView` (via representable) drawing the trail polyline + endpoint
/// markers, auto-zoomed to fit. iOS 17's SwiftUI `Map`/`MapPolyline` is unusable
/// here (SDK floor is iOS 15 / macOS 13), so we bridge UIKit/AppKit MapKit.
private struct CmsTrailMapView {
    let points: [CmsTrailMapBlockView.LatLng]
    let strokeColor: Color
    let strokeWeight: CGFloat
    let showMarkers: Bool

    func makeCoordinator() -> CmsTrailMapCoordinator {
        CmsTrailMapCoordinator(strokeColor: strokeColor, strokeWeight: strokeWeight)
    }

    private var pathKey: String {
        // count + endpoints uniquely identify a re-fit-worthy change cheaply.
        guard let first = points.first, let last = points.last else { return "empty" }
        return "\(points.count):\(first.lat),\(first.lng):\(last.lat),\(last.lng)"
    }

    private func configure(_ mapView: MKMapView, coordinator: CmsTrailMapCoordinator) {
        coordinator.strokeColor = strokeColor
        coordinator.strokeWeight = strokeWeight

        guard coordinator.lastKey != pathKey else { return }
        coordinator.lastKey = pathKey

        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        guard !coords.isEmpty else { return }

        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        mapView.addOverlay(polyline)

        if showMarkers, let first = coords.first, let last = coords.last {
            mapView.addAnnotation(CmsTrailEndpoint(coordinate: first, isStart: true))
            mapView.addAnnotation(CmsTrailEndpoint(coordinate: last, isStart: false))
        }

        // Fit the path with a little breathing room.
        let rect = polyline.boundingMapRect
        #if os(iOS)
        let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
        #elseif os(macOS)
        let padding = NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
        #endif
        mapView.setVisibleMapRect(rect, edgePadding: padding, animated: false)
    }

    private func makeMap(coordinator: CmsTrailMapCoordinator) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = coordinator
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        #if os(iOS)
        mapView.pointOfInterestFilter = .excludingAll
        #endif
        configure(mapView, coordinator: coordinator)
        return mapView
    }
}

#if os(iOS)
extension CmsTrailMapView: UIViewRepresentable {
    func makeUIView(context: Context) -> MKMapView { makeMap(coordinator: context.coordinator) }
    func updateUIView(_ mapView: MKMapView, context: Context) {
        configure(mapView, coordinator: context.coordinator)
    }
}
#elseif os(macOS)
extension CmsTrailMapView: NSViewRepresentable {
    func makeNSView(context: Context) -> MKMapView { makeMap(coordinator: context.coordinator) }
    func updateNSView(_ mapView: MKMapView, context: Context) {
        configure(mapView, coordinator: context.coordinator)
    }
}
#endif
