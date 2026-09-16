#if os(iOS)
  import MapKit
  import UIKit

  /// Installed, data-driven MapKit content. Placement/lifetime stay in NativeEmbedController.
  @MainActor final class NativeMapRenderer: NativeEmbeddedRenderer {
    let viewController = UIViewController()
    let map = MKMapView()
    private let explore = UIButton(type: .system)
    private let openMaps = UIButton(type: .system)
    private let label = UILabel()
    private final class Delegate: NSObject, MKMapViewDelegate {
      weak var owner: NativeMapRenderer?
      func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
        owner?.mapView(mapView, didSelect: annotation)
      }
      func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        owner?.mapView(mapView, regionDidChangeAnimated: animated)
      }
    }
    private let delegate = Delegate()
    private var pins: [Pin] = []
    private var applying = false
    private var regionKey: String?
    private var selectedID: String?
    var onEvent: (([String: Any]) -> Void)?
    var onSizeChange: (() -> Void)?
    private(set) var isEditing = false
    var ownsScrollGestures: Bool { isEditing }
    var accessibilityElements: [Any] { [viewController.view!] }

    final class Pin: NSObject, MKAnnotation {
      let id: String
      let title: String?
      let coordinate: CLLocationCoordinate2D
      init(id: String, title: String, latitude: Double, longitude: Double) {
        self.id = id; self.title = title
        coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
      }
    }
    enum InvalidSnapshot: Error { case invalid }
    struct Snapshot {
      let region: MKCoordinateRegion
      let pins: [Pin]
      let selectedID: String?
      init(_ value: [String: Any]) throws {
        func number(_ value: Any?, _ range: ClosedRange<Double>) throws -> Double {
          guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
            n.doubleValue.isFinite, range.contains(n.doubleValue)
          else { throw InvalidSnapshot.invalid }
          return n.doubleValue
        }
        guard let camera = value["camera"] as? [String: Any],
          let items = value["pins"] as? [[String: Any]], items.count <= 100
        else { throw InvalidSnapshot.invalid }
        region = MKCoordinateRegion(
          center: CLLocationCoordinate2D(
            latitude: try number(camera["latitude"], -85...85),
            longitude: try number(camera["longitude"], -180...180)),
          span: MKCoordinateSpan(
            latitudeDelta: try number(camera["latitudeDelta"], 0.0001...170),
            longitudeDelta: try number(camera["longitudeDelta"], 0.0001...360)))
        var ids = Set<String>()
        pins = try items.map { item in
          guard let id = item["id"] as? String, !id.isEmpty, id.count <= 100,
            ids.insert(id).inserted, let title = item["title"] as? String,
            !title.isEmpty, title.count <= 160
          else { throw InvalidSnapshot.invalid }
          return Pin(id: id, title: title,
            latitude: try number(item["latitude"], -90...90),
            longitude: try number(item["longitude"], -180...180))
        }
        if let selected = value["selectedId"], !(selected is NSNull) {
          guard let id = selected as? String, ids.contains(id) else { throw InvalidSnapshot.invalid }
          selectedID = id
        } else { selectedID = nil }
      }
    }
    init() {
      delegate.owner = self
      let root = viewController.view!
      root.accessibilityIdentifier = "NativeMap.root"
      root.backgroundColor = .systemBackground
      map.delegate = delegate
      map.accessibilityIdentifier = "NativeMap.map"
      map.showsUserLocation = false
      map.isPitchEnabled = false
      map.isRotateEnabled = false
      map.isScrollEnabled = false
      map.isZoomEnabled = false
      map.pointOfInterestFilter = .excludingAll
      let heading = UILabel()
      heading.text = "Places"
      heading.font = .preferredFont(forTextStyle: .headline)
      explore.setTitle("Explore map", for: .normal)
      explore.accessibilityIdentifier = "NativeMap.explore"
      explore.addAction(UIAction { [weak self] _ in self?.toggleExplore() }, for: .touchUpInside)
      let top = UIStackView(arrangedSubviews: [heading, explore])
      top.distribution = .equalSpacing
      label.text = "Choose a pin"
      label.font = .preferredFont(forTextStyle: .subheadline)
      label.adjustsFontForContentSizeCategory = true
      label.numberOfLines = 2
      label.accessibilityIdentifier = "NativeMap.selection"
      openMaps.setTitle("Open in Maps", for: .normal)
      openMaps.accessibilityIdentifier = "NativeMap.open"
      openMaps.isEnabled = false
      openMaps.addAction(UIAction { [weak self] _ in self?.openSelected() }, for: .touchUpInside)
      openMaps.setContentCompressionResistancePriority(.required, for: .horizontal)
      let bottom = UIStackView(arrangedSubviews: [label, openMaps])
      bottom.spacing = 8
      bottom.alignment = .center
      let stack = UIStackView(arrangedSubviews: [top, map, bottom])
      stack.axis = .vertical
      stack.spacing = 8
      stack.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
        stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
        stack.topAnchor.constraint(equalTo: root.topAnchor),
        stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        top.heightAnchor.constraint(equalToConstant: 44),
        bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      ])
    }
    func sizeThatFits(width: CGFloat) -> CGSize { CGSize(width: width, height: 360) }
    func update(snapshot: [String: Any]) throws {
      let next = try Snapshot(snapshot) // Validate before changing any native state.
      applying = true
      defer { applying = false }
      if pins.map({ "\($0.id):\($0.title ?? ""):\($0.coordinate.latitude):\($0.coordinate.longitude)" })
        != next.pins.map({ "\($0.id):\($0.title ?? ""):\($0.coordinate.latitude):\($0.coordinate.longitude)" }) {
        map.removeAnnotations(pins)
        pins = next.pins
        map.addAnnotations(pins)
      }
      let key = Self.key(next.region)
      if regionKey != key {
        regionKey = key
        map.setRegion(next.region, animated: false)
      }
      selectedID = next.selectedID
      if let pin = pins.first(where: { $0.id == selectedID }) {
        if !map.selectedAnnotations.contains(where: { ($0 as? Pin)?.id == pin.id }) {
          map.selectAnnotation(pin, animated: false)
        }
      } else {
        for pin in map.selectedAnnotations { map.deselectAnnotation(pin, animated: false) }
      }
      refreshSelection()
    }
    func toggleExplore() {
      isEditing.toggle()
      map.isScrollEnabled = isEditing
      map.isZoomEnabled = isEditing
      explore.setTitle(isEditing ? "Done" : "Explore map", for: .normal)
      onSizeChange?()
    }
    private func refreshSelection() {
      label.text = pins.first(where: { $0.id == selectedID })?.title ?? "Choose a pin"
      openMaps.isEnabled = selectedID != nil
    }
    private func openSelected() {
      guard let pin = pins.first(where: { $0.id == selectedID }) else { return }
      let item = MKMapItem(placemark: MKPlacemark(coordinate: pin.coordinate))
      item.name = pin.title
      item.openInMaps(launchOptions: nil)
    }
    func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
      guard !applying, let pin = annotation as? Pin, selectedID != pin.id else { return }
      selectedID = pin.id
      refreshSelection()
      onEvent?(["type": "select", "id": pin.id])
    }
    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
      guard !applying, isEditing else { return }
      let r = mapView.region
      // A completed camera move is semantic state; no per-frame bridge traffic.
      regionKey = Self.key(r)
      onEvent?(["type": "camera", "camera": [
        "latitude": min(85, max(-85, r.center.latitude)), "longitude": r.center.longitude,
        "latitudeDelta": min(170, max(0.0001, r.span.latitudeDelta)),
        "longitudeDelta": min(360, max(0.0001, r.span.longitudeDelta)),
      ]])
    }
    private static func key(_ r: MKCoordinateRegion) -> String {
      "\(r.center.latitude):\(r.center.longitude):\(r.span.latitudeDelta):\(r.span.longitudeDelta)"
    }
  }
#endif
