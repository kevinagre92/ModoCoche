import SwiftUI
import MapKit
import Combine
import Contacts
import Network
import UIKit
import MediaPlayer
import AVFoundation
import CoreLocation
import EventKit
import WeatherKit
import SpotifyiOS


// =====================================================
// MARK: - Panel enum
// =====================================================
enum Panel {
    case map, music, contacts, home
}

// =====================================================
// MARK: - App UI Tuning (CarPlay-like)
// =====================================================
private enum CarPlayUI {
    static let centerHeightFactor: CGFloat = 0.60
    static let sidebarWidth: CGFloat = 84

    static let panelCorner: CGFloat = 26
    static let sidebarCorner: CGFloat = 28

    static let homeRows: CGFloat = 2
    static let homeGridSpacing: CGFloat = 12
    static let homeTileMinHeight: CGFloat = 70

    static let rightColumnWidth: CGFloat = 325

    // Now Playing (Right column)
    static let nowPlayingArtworkCorner: CGFloat = 22
    static let nowPlayingArtworkHeight: CGFloat = 175   // ⬅️ carátula grande tipo CarPlay
    static let nowPlayingControlsHeight: CGFloat = 46
}

// =====================================================
// MARK: - ContentView
// =====================================================
struct ContentView: View {
    @State private var selectedPanel: Panel = .home

    @StateObject private var contactsManager = ContactsManager()
    @StateObject private var calendarManager = AppCalendarManager()
    @StateObject private var locationManager = AppLocationManager()
    @StateObject private var placesCompleter = PlacesCompleter()
    @StateObject private var weatherManager = WeatherManager()

    @State private var searchDebounceTask: Task<Void, Never>? = nil
    @State private var showingFavoritesSheet: Bool = false
    @State private var configuringFavorite: FavoriteKind? = nil

    @AppStorage("favorite_home") private var favoriteHomeJSON: String = ""
    @AppStorage("favorite_work") private var favoriteWorkJSON: String = ""

    @State private var mapStyle: MapStyle = .standard
    @State private var mapExpanded: Bool = false
    
    @StateObject private var locationTime = LocationTimeManager()

    @FocusState private var searchFocused: Bool
    @State private var searchFullscreen: Bool = false
    @State private var activeSearch: MKLocalSearch? = nil
    @State private var activeRoute: MKRoute? = nil
    @State private var routing = false
    @State private var routeError: String? = nil
    @State private var showingRouteError: Bool = false
    @State private var routeSteps: [MKRoute.Step] = []
    @State private var isSearchingPlaces: Bool = false

    @State private var showSiriHelp = false
    private func triggerSiri() { showSiriHelp = true }

    @State private var currentStepIndex: Int = 0
    @State private var isGuiding: Bool = false
    @State private var distanceToNextStep: CLLocationDistance? = nil

    @Environment(\.colorScheme) private var systemScheme
    @AppStorage("appTheme") private var appTheme: String = "system"

    private var effectiveScheme: ColorScheme {
        switch appTheme {
        case "dark": return .dark
        case "light": return .light
        default: return systemScheme
        }
    }

    @State private var mapHeight: CGFloat = 0

    @State private var position: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 28.1248, longitude: -15.4300),
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )
    )

    // búsqueda (mapa)
    @State private var searchText: String = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var showingResults: Bool = false

    // “Ir”
    @State private var pendingDestination: MKMapItem? = nil
    @State private var showGoPrompt: Bool = false

    // métricas navegación
    @State private var routeStartDate: Date? = nil
    @State private var navTotalTime: TimeInterval = 0
    @State private var navRemainingTime: TimeInterval = 0
    @State private var navTotalDistance: CLLocationDistance = 0
    @State private var navRemainingDistance: CLLocationDistance = 0

    // búsqueda (contactos)
    @State private var contactsSearchText: String = ""
    @FocusState private var contactsSearchFocused: Bool

    // modo brújula
    @State private var compassMode: Bool = true

    // timer navegación
    private let navTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    // =====================================================
    // Mantener pantalla encendida (no bloqueo)
    // =====================================================
    @State private var keepScreenOn: Bool = false

    private func setIdleTimer(_ disabled: Bool) {
        guard keepScreenOn != disabled else { return }
        keepScreenOn = disabled
        UIApplication.shared.isIdleTimerDisabled = disabled
    }

    var body: some View {
        GeometryReader { geo in
            let targetHeight = geo.size.height * 0.93     // Contactos / Mapa / Música
            let homeHeight   = geo.size.height * 0.84     // Home

            ZStack {
                backgroundView

                VStack {
                    Spacer(minLength: 0)
                        .frame(height: geo.size.height * 0.012)

                    HStack(alignment: .top, spacing: 16) {

                        // MARK: - Sidebar
                        if !searchFullscreen {
                            sidebar(height: targetHeight)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                        }

                        // MARK: - Center
                        ZStack {
                            switch selectedPanel {
                            case .home:
                                HomePanel(hasSidebar: !searchFullscreen, keepScreenOn: $keepScreenOn)

                            case .map:
                                mapPanel
                                    .padding(.leading, 25)
                                    .padding(.trailing, 5)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                            case .contacts:
                                contactsPanel
                                    .padding(.leading, 25)
                                    .padding(.trailing, 5)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                            case .music:
                                CarPlayNowPlayingPanel()
                                    .padding(.leading, 25)
                                    .padding(.trailing, 5)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: selectedPanel == .home ? homeHeight : targetHeight, alignment: .top)

                        // MARK: - Right
                        if !mapExpanded && !searchFullscreen && selectedPanel != .home {

                            VStack(spacing: -40) {   // 👈 este spacing controla el hueco entre música y calendario

                                // 🎵 Música arriba
                                chromeCard(padding: 16) {
                                    if selectedPanel == .music {
                                        RightWeatherCard(wm: weatherManager)
                                    } else {
                                        RightNowPlayingCard()
                                    }
                                }

                                .frame(height: 100, alignment: .top)

                                .frame(height: 220, alignment: .top)

                                if isGuiding && !routeSteps.isEmpty && currentStepIndex < routeSteps.count {

                                    // 🧭 En ruta: indicaciones ocupan el resto
                                    chromeCard(padding: 16) {
                                        let instr = routeSteps[currentStepIndex].instructions
                                        RouteGuidanceSidebar(
                                            instruction: instr,
                                            iconName: maneuverIcon(for: instr, isLast: currentStepIndex == routeSteps.count - 1),
                                            stepIndex: currentStepIndex,
                                            totalSteps: routeSteps.count,
                                            onEnd: { endRoute() }
                                        )
                                    }
                                    .frame(maxHeight: .infinity, alignment: .topLeading)

                                } else {

                                    // 📅 Calendario justo debajo de música (NO al fondo)
                                    chromeCard(padding: 16) {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text("Eventos para hoy")
                                                .font(.system(size: 16, weight: .semibold))

                                            CalendarWidget(calendarManager: calendarManager)
                                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                                .padding(.bottom, 4)   // ⬅️ ESTE es el “suelo”

                                        }
                                    }
                                    .frame(height: 210, alignment: .top)
                                }
                            }
                            .frame(width: CarPlayUI.rightColumnWidth, height: targetHeight, alignment: .top)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }

                    }
                    .padding(.horizontal, searchFullscreen ? 0 : 18)
                    .padding(.vertical, searchFullscreen ? 0 : 18)
                    .onAppear {
                        setIdleTimer(true)
                        mapHeight = targetHeight
                        calendarManager.requestAccessAndFetch()
                        locationTime.start(with: locationManager)
                    }
                    .onDisappear { setIdleTimer(false) }
                    .onChange(of: geo.size.height) { _, _ in
                        mapHeight = geo.size.height * 0.70
                    }
                    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                        guard compassMode, let c = locationManager.coordinate else { return }
                        centerOn(c, heading: locationManager.heading)
                    }
                    .onChange(of: keepScreenOn) { _, v in setIdleTimer(v) }

                    Spacer(minLength: 0)
                }
            }
            .ignoresSafeArea(.keyboard)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in setIdleTimer(false) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in setIdleTimer(true) }
            .alert("Siri", isPresented: $showSiriHelp) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("iOS no permite abrir Siri directamente desde una app. Usa el botón lateral o di “Oye Siri”.")
            }
            .onChange(of: searchFocused) { _, focused in
                withAnimation(.easeInOut(duration: 0.2)) {
                    searchFullscreen = focused
                    if focused { mapExpanded = true }
                }
            }
            .onChange(of: contactsSearchFocused) { _, focused in
                withAnimation(.easeInOut(duration: 0.2)) {
                    searchFullscreen = focused
                    if focused { mapExpanded = true }
                }
            }
            .preferredColorScheme(appTheme == "system" ? nil : effectiveScheme)
            .sheet(isPresented: $showingFavoritesSheet) {
                FavoriteSetupSheet(
                    kind: configuringFavorite ?? .home,
                    initialRegion: currentRegionForSuggestions(),
                    onSave: { kind, item in
                        let coord = item.placemark.coordinate
                        let saved = SavedPlace(
                            name: item.name ?? kind.title,
                            lat: coord.latitude,
                            lon: coord.longitude
                        )
                        setFavoriteJSON(encodeSavedPlace(saved), for: kind)
                    }
                )
            }
        }
    }

    // =====================================================
    // MARK: - Sidebar
    // =====================================================
    private func sidebar(height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: CarPlayUI.sidebarCorner, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: CarPlayUI.sidebarCorner, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )

            VStack(spacing: 10) {
                SideStatusBar()

                if selectedPanel != .map {
                    SideButton(icon: "map.fill", title: "Mapa", selected: selectedPanel == .map, showTitle: false) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedPanel = .map
                            mapExpanded = false
                        }
                    }
                }

                if selectedPanel != .music {
                    SideButton(icon: "music.note", title: "Música", selected: selectedPanel == .music, showTitle: false) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedPanel = .music
                            mapExpanded = false
                        }
                    }
                }

                if selectedPanel != .contacts {
                    SideButton(icon: "person.crop.circle.fill", title: "Contactos", selected: selectedPanel == .contacts, showTitle: false) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedPanel = .contacts
                            mapExpanded = false
                        }
                    }
                }

                SideButton(icon: "waveform.circle.fill", title: "Siri", selected: false, showTitle: false) {
                    triggerSiri()
                }

                Spacer(minLength: 0)

                if selectedPanel != .home {
                    SideButton(icon: "square.grid.2x2.fill", title: "Inicio", selected: selectedPanel == .home, showTitle: false) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            selectedPanel = .home
                            mapExpanded = false
                            searchFullscreen = false
                            setIdleTimer(true)
                            mapHeight = height
                            calendarManager.requestAccessAndFetch()
                        }
                    }
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: CarPlayUI.sidebarWidth, height: height, alignment: .top)
        .shadow(color: Color.black.opacity(effectiveScheme == .dark ? 0.25 : 0.12), radius: 14, x: 0, y: 10)
        .animation(.easeInOut(duration: 0.20), value: selectedPanel)
    }

    // =====================================================
    // MARK: - Right column
    // =====================================================
    private func rightColumn(height: CGFloat) -> some View {
        VStack(spacing: 16) {

            // ✅ Card de música PRO (SIN cabecera, carátula grande)
            chromeCard(padding: 0) {
                RightNowPlayingCard()
            }
            .frame(minHeight: 220)

            if isGuiding && !routeSteps.isEmpty && currentStepIndex < routeSteps.count {
                infoCard(title: "Indicaciones", subtitle: "") {
                    let instr = routeSteps[currentStepIndex].instructions
                    RouteGuidanceSidebar(
                        instruction: instr,
                        iconName: maneuverIcon(for: instr, isLast: currentStepIndex == routeSteps.count - 1),
                        stepIndex: currentStepIndex,
                        totalSteps: routeSteps.count,
                        onEnd: { endRoute() }
                    )
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            } else {
                infoCard(title: "Eventos para hoy", subtitle: "") {
                    CalendarWidget(calendarManager: calendarManager)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            }
        }
        .frame(width: CarPlayUI.rightColumnWidth, height: height, alignment: .top)
    }

    // =====================================================
    // ETA bar
    // =====================================================
    private var etaBar: some View {
        HStack(spacing: 12) {
            Button { endRoute() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.red.opacity(0.95))
                    .clipShape(Circle())
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                navMetric(value: formatArrivalTime(), label: "hora estimada")
                navMetric(value: formatDuration(navTotalTime), label: "duración")
                navMetric(value: formatDistance(navRemainingDistance), label: "distancia")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: 360, alignment: .leading)
        .shadow(color: Color.black.opacity(effectiveScheme == .dark ? 0.22 : 0.10), radius: 10, x: 0, y: 6)
    }

    private func navMetric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: true, vertical: false)

            Text(label)
                .font(.system(size: 10, weight: .medium))
                .opacity(0.55)
        }
    }

    private func formatArrivalTime() -> String {
        guard let start = routeStartDate else { return "--:--" }
        let arrival = start.addingTimeInterval(navTotalTime)
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_ES")
        df.dateFormat = "HH:mm"
        return df.string(from: arrival)
    }

    // =====================================================
    // MARK: - MAP PANEL
    // =====================================================
    private var mapPanel: some View {
        ZStack(alignment: .top) {

            Map(position: $position, interactionModes: isGuiding ? [] : [.pan, .zoom, .rotate]) {
                UserAnnotation()
                if let route = activeRoute {
                    MapPolyline(route.polyline)
                        .stroke(.blue, lineWidth: 6)
                }
            }
            .mapStyle(mapStyle)
            .clipShape(RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(effectiveScheme == .dark ? 0.20 : 0.10), radius: 14, x: 0, y: 10)
            .onAppear { locationManager.requestPermission() }
            .onReceive(locationManager.$coordinate.compactMap { $0 }) { c in
                locationTime.coordinateDidChange(c)
                weatherManager.updateIfNeeded(coord: c)
            }

            .onReceive(locationManager.$coordinate.compactMap { $0 }) { coord in
                if isGuiding {
                    updateGuidanceProgress(user: coord)
                    updateNavigationCamera(user: coord)
                    return
                }
                if !showingResults && searchText.isEmpty {
                    centerOn(coord, heading: compassMode ? locationManager.heading : nil)
                }
            }
            .onReceive(locationManager.$heading) { h in
                guard compassMode, let c = locationManager.coordinate else { return }
                centerOn(c, heading: h)
            }

            // Search bar (cuando NO está en ruta)
            if !isGuiding {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").opacity(0.7)

                        TextField("Buscar destino…", text: $searchText)
                            .submitLabel(.search)
                            .focused($searchFocused)
                            .onSubmit {
                                hideKeyboard()
                                Task { await searchPlaces() }
                            }
                            .onChange(of: searchText) { _, newValue in
                                searchDebounceTask?.cancel()
                                searchDebounceTask = Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 180_000_000)
                                    placesCompleter.update(query: newValue, region: currentRegionForSuggestions())
                                }
                            }

                        Button("Buscar") {
                            hideKeyboard()
                            Task { await searchPlaces() }
                        }
                        .font(.system(size: 15, weight: .semibold))

                        if searchFocused {
                            Button {
                                hideKeyboard()
                                searchFocused = false
                            } label: {
                                Image(systemName: "keyboard.chevron.compact.down")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                            .opacity(0.9)
                            .transition(.opacity.combined(with: .scale))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                    .animation(.easeInOut(duration: 0.15), value: searchFocused)

                    // Favoritos
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchFocused && !isGuiding {
                        HStack(spacing: 10) {
                            Button {
                                hideKeyboard()
                                openFavorite(.home)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "house.fill")
                                    Text("Casa").font(.system(size: 14, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Button {
                                hideKeyboard()
                                openFavorite(.work)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "briefcase.fill")
                                    Text("Trabajo").font(.system(size: 14, weight: .semibold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                            }
                            .buttonStyle(.plain)

                            Spacer()
                        }
                        .padding(.horizontal, 12)
                    }

                    // Sugerencias
                    if searchFocused && !placesCompleter.results.isEmpty && !isGuiding {
                        ScrollView {
                            VStack(spacing: 10) {
                                ForEach(placesCompleter.results, id: \.self) { completion in
                                    Button {
                                        hideKeyboard()
                                        searchFocused = false
                                        searchFullscreen = false
                                        Task { @MainActor in
                                            if let item = await resolveCompletionToMapItem(completion) {
                                                pendingDestination = item
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    showGoPrompt = true
                                                }
                                            }
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(completion.title)
                                                .font(.system(size: 14, weight: .semibold))
                                            if !completion.subtitle.isEmpty {
                                                Text(completion.subtitle)
                                                    .font(.system(size: 12))
                                                    .opacity(0.8)
                                                    .lineLimit(2)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(12)
                                        .background(.ultraThinMaterial)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 10)
                        }
                        .frame(maxHeight: 260)
                    }
                }
            }

            // Controles derecha
            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        controlButton("location.fill") {
                            if let c = locationManager.coordinate {
                                centerOn(c, heading: compassMode ? locationManager.heading : nil)
                            }
                        }

                        controlButton(compassMode ? "location.north.line.fill" : "location.north.line") {
                            compassMode.toggle()
                            if let c = locationManager.coordinate {
                                centerOn(c, heading: compassMode ? locationManager.heading : nil)
                            }
                        }

                        controlButton("xmark") {
                            showGoPrompt = false
                            pendingDestination = nil
                            activeRoute = nil
                            routeError = nil
                            endRoute()
                        }

                        Menu {
                            Button("Estándar") { mapStyle = .standard }
                            Button("Híbrido") { mapStyle = .hybrid }
                            Button("Satélite") { mapStyle = .imagery }
                        } label: {
                            Image(systemName: "map")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial)
                                .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1))
                                .clipShape(Circle())
                        }
                    }
                }
                .padding(.trailing, 14)
                .padding(.top, 94)

                Spacer()

                HStack {
                    Spacer()
                    controlButton(mapExpanded ? "arrow.left.to.line" : "arrow.right.to.line") {
                        withAnimation(.easeInOut(duration: 0.25)) { mapExpanded.toggle() }
                    }
                    .padding(14)
                }
            }

            // Panel “Ir”
            if showGoPrompt, let dest = pendingDestination, !isGuiding {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dest.name ?? "Destino")
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                            Text(dest.placemark.title ?? "")
                                .font(.system(size: 12))
                                .opacity(0.75)
                                .lineLimit(1)
                        }

                        Spacer()

                        Button("Cancelar") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showGoPrompt = false
                                pendingDestination = nil
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.bordered)

                        Button("Ir") {
                            guard pendingDestination != nil else { return }
                            withAnimation(.easeInOut(duration: 0.2)) { showGoPrompt = false }
                            let d = pendingDestination
                            pendingDestination = nil
                            if let d { routeTo(d) }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(14)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // INSTRUCCIONES SOBRE EL MAPA (fullscreen)
            if mapExpanded && isGuiding && !routeSteps.isEmpty && currentStepIndex < routeSteps.count {
                let instr = routeSteps[currentStepIndex].instructions
                let icon = maneuverIcon(for: instr, isLast: currentStepIndex == routeSteps.count - 1)

                VStack(alignment: .leading) {
                    HStack(spacing: 12) {
                        Image(systemName: icon)
                            .font(.system(size: 30, weight: .bold))
                            .frame(width: 40)

                        Text(instr.isEmpty ? "Continúa" : instr)
                            .font(.system(size: 24, weight: .bold))
                            .lineLimit(3)
                            .minimumScaleFactor(0.70)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .frame(maxWidth: 420, alignment: .leading)

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.leading, 18)
                .padding(.top, 18)
                .zIndex(30)
            }

            // ETA — arriba izquierda cuando NO es fullscreen
            if isGuiding && !mapExpanded {
                HStack {
                    etaBar
                    Spacer()
                }
                .padding(.leading, 18)
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .zIndex(20)
            }

            // ETA — abajo centrada cuando SÍ es fullscreen
            if isGuiding && mapExpanded {
                HStack {
                    Spacer()
                    etaBar
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .zIndex(20)
            }
        }
        .onReceive(navTimer) { _ in
            guard isGuiding else { return }
            updateNavMetricsTick()
        }
    }

    // =====================================================
    // CONTACTS PANEL
    // =====================================================
    private var contactsPanel: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(effectiveScheme == .dark ? 0.20 : 0.10), radius: 14, x: 0, y: 10)

            ContactsPanel(contactsManager: contactsManager, query: $contactsSearchText)
                .padding(.top, 64)
                .padding(.horizontal, 12)
                .padding(.bottom, 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").opacity(0.7)

                TextField("Buscar contacto…", text: $contactsSearchText)
                    .submitLabel(.search)
                    .focused($contactsSearchFocused)

                Button {
                    contactsSearchText = ""
                    hideKeyboard()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.85)
                }

                if contactsSearchFocused {
                    Button {
                        hideKeyboard()
                        contactsSearchFocused = false
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .opacity(0.9)
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: contactsSearchFocused)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .padding(.top, 12)
            .padding(.horizontal, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous))
    }

    // =====================================================
    // Map helpers
    // =====================================================
    private func centerOn(_ coord: CLLocationCoordinate2D, heading: CLLocationDirection?) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if let heading {
                position = .camera(
                    MapCamera(
                        centerCoordinate: coord,
                        distance: 800,
                        heading: adjustedHeading(heading),
                        pitch: 0
                    )
                )
            } else {
                position = .region(
                    MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                )
            }
        }
    }

    private func routeTo(_ destination: MKMapItem) {
        routeError = nil
        routing = true
        activeRoute = nil

        routeStartDate = nil
        navTotalTime = 0
        navRemainingTime = 0
        navTotalDistance = 0
        navRemainingDistance = 0

        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = .automobile

        MKDirections(request: request).calculate { response, error in
            DispatchQueue.main.async {
                routing = false

                if let error = error {
                    routeError = error.localizedDescription
                    showingRouteError = true
                    return
                }

                guard let route = response?.routes.first else {
                    routeError = "No se pudo calcular la ruta."
                    showingRouteError = true
                    return
                }

                activeRoute = route
                position = .rect(route.polyline.boundingMapRect)

                routeSteps = route.steps.filter { !$0.instructions.isEmpty }
                currentStepIndex = 0
                isGuiding = true

                routeStartDate = Date()
                navTotalTime = route.expectedTravelTime
                navRemainingTime = route.expectedTravelTime
                navTotalDistance = route.distance
                navRemainingDistance = route.distance

                if let c = locationManager.coordinate {
                    updateNavigationCamera(user: c)
                }
            }
        }
    }

    private func endRoute() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isGuiding = false
            activeRoute = nil
            routeSteps = []
            currentStepIndex = 0
            distanceToNextStep = nil

            routeStartDate = nil
            navTotalTime = 0
            navRemainingTime = 0
            navTotalDistance = 0
            navRemainingDistance = 0

            showingResults = false
            showGoPrompt = false
            pendingDestination = nil
        }
    }

    private func updateNavMetricsTick() {
        guard let start = routeStartDate else { return }
        guard navTotalTime > 0 else { return }

        let elapsed = Date().timeIntervalSince(start)
        let remaining = max(0, navTotalTime - elapsed)
        navRemainingTime = remaining

        let ratio = max(0, min(1, remaining / navTotalTime))
        navRemainingDistance = navTotalDistance * ratio
    }

    private func adjustedHeading(_ raw: CLLocationDirection) -> CLLocationDirection {
        let o = interfaceOrientation()

        let offset: CLLocationDirection
        switch o {
        case .landscapeLeft: offset = -90
        case .landscapeRight: offset = 90
        case .portrait: offset = 0
        case .portraitUpsideDown: offset = 180
        default: offset = -90
        }

        var h = raw + offset
        while h < 0 { h += 360 }
        while h >= 360 { h -= 360 }
        return h
    }

    private func interfaceOrientation() -> UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        return windowScene?.interfaceOrientation ?? .unknown
    }

    @MainActor
    private func searchPlaces() async {
        if isSearchingPlaces { return }
        isSearchingPlaces = true
        defer { isSearchingPlaces = false }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            showingResults = false
            searchResults = []
            return
        }

        activeSearch?.cancel()
        activeSearch = nil

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = q

        if let c = locationManager.coordinate {
            request.region = MKCoordinateRegion(
                center: c,
                span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
            )
        }

        let search = MKLocalSearch(request: request)
        activeSearch = search

        do {
            let response = try await search.start()
            let items = response.mapItems

            if activeSearch === search {
                self.searchResults = items
                self.showingResults = true
            }
        } catch {
            if activeSearch === search {
                self.searchResults = []
                self.showingResults = true
            }
        }

        if activeSearch === search { activeSearch = nil }
    }

    private func currentRegionForSuggestions() -> MKCoordinateRegion? {
        guard let c = locationManager.coordinate else { return nil }
        return MKCoordinateRegion(
            center: c,
            span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15)
        )
    }

    @MainActor
    private func resolveCompletionToMapItem(_ completion: MKLocalSearchCompletion) async -> MKMapItem? {
        let req = MKLocalSearch.Request(completion: completion)
        if let c = locationManager.coordinate {
            req.region = MKCoordinateRegion(center: c, span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15))
        }
        do {
            let resp = try await MKLocalSearch(request: req).start()
            return resp.mapItems.first
        } catch {
            return nil
        }
    }

    private func favoriteJSON(for kind: FavoriteKind) -> String {
        kind == .home ? favoriteHomeJSON : favoriteWorkJSON
    }

    private func setFavoriteJSON(_ value: String, for kind: FavoriteKind) {
        if kind == .home { favoriteHomeJSON = value } else { favoriteWorkJSON = value }
    }

    private func savedPlace(for kind: FavoriteKind) -> SavedPlace? {
        decodeSavedPlace(favoriteJSON(for: kind))
    }

    private func openFavorite(_ kind: FavoriteKind) {
        if let sp = savedPlace(for: kind) {
            let coord = CLLocationCoordinate2D(latitude: sp.lat, longitude: sp.lon)
            let item = MKMapItem(placemark: MKPlacemark(coordinate: coord))
            item.name = sp.name
            pendingDestination = item
            withAnimation(.easeInOut(duration: 0.2)) { showGoPrompt = true }
        } else {
            configuringFavorite = kind
            showingFavoritesSheet = true
        }
    }

    private func updateGuidanceProgress(user coord: CLLocationCoordinate2D) {
        guard currentStepIndex < routeSteps.count else {
            distanceToNextStep = nil
            isGuiding = false
            return
        }

        let step = routeSteps[currentStepIndex]
        let coords = step.polyline.coordinates
        guard let target = coords.last else { return }

        let d = distance(from: coord, to: target)
        distanceToNextStep = d

        if d < 25 {
            if currentStepIndex < routeSteps.count - 1 {
                currentStepIndex += 1
            } else {
                isGuiding = false
                distanceToNextStep = nil
            }
        }
    }

    private func distance(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let s = Int(max(0, seconds))
        let m = (s + 30) / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        let mm = m % 60
        return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
    }

    private func formatDistance(_ meters: CLLocationDistance) -> String {
        let m = max(0, meters)
        if m >= 1000 {
            let km = m / 1000.0
            return String(format: "%.1fkm", km)
        } else {
            return "\(Int(m))m"
        }
    }

    private func controlButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial)
                .overlay(Circle().stroke(Color.primary.opacity(0.10), lineWidth: 1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func placeholderPanel(_ text: String) -> some View {
        chromeCard {
            Text(text)
                .multilineTextAlignment(.center)
                .opacity(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // =====================================================
    // MARK: - Cards / chrome
    // =====================================================
    private func chromeCard<Content: View>(padding: CGFloat = 16, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous))
        .shadow(color: Color.black.opacity(effectiveScheme == .dark ? 0.18 : 0.08), radius: 12, x: 0, y: 10)
    }

    private func infoCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        chromeCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(title).font(.system(size: 16, weight: .semibold))
                }
                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle).font(.system(size: 14)).opacity(0.85)
                }
                content()
            }
        }
        .frame(minHeight: 181, alignment: .topLeading)
    }

    private var backgroundView: some View {
        Image(effectiveScheme == .dark ? "bg_dark" : "bg_light")
            .resizable()
            .scaledToFill()
            .overlay(effectiveScheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.20))
            .ignoresSafeArea()
    }

    private func maneuverIcon(for instruction: String, isLast: Bool) -> String {
        let s = instruction.lowercased()
        if isLast { return "flag.checkered" }
        if s.contains("has llegado") || s.contains("destino") { return "flag.checkered" }
        if s.contains("rotonda") || s.contains("glorieta") { return "arrow.triangle.turn.up.right.circle" }
        if s.contains("incorp") || s.contains("toma la salida") { return "arrow.merge" }
        if s.contains("izquierda") { return "arrow.turn.up.left" }
        if s.contains("derecha") { return "arrow.turn.up.right" }
        if s.contains("continúa") || s.contains("sigue") || s.contains("recto") { return "arrow.up" }
        return "arrow.up"
    }

    private func updateNavigationCamera(user coord: CLLocationCoordinate2D) {
        guard let rawHeading = locationManager.heading else {
            centerOn(coord, heading: nil)
            return
        }

        let heading = adjustedHeading(rawHeading)

        withAnimation(.easeInOut(duration: 0.22)) {
            position = .camera(
                MapCamera(
                    centerCoordinate: coord,
                    distance: 850,
                    heading: heading,
                    pitch: 60
                )
            )
        }
    }
}

// =====================================================
// MARK: - Live Suggestions (MKLocalSearchCompleter)
// =====================================================
final class PlacesCompleter: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String, region: MKCoordinateRegion?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            results = []
            completer.queryFragment = ""
            return
        }
        if let region { completer.region = region }
        completer.queryFragment = q
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        DispatchQueue.main.async {
            self.results = Array(completer.results.prefix(8))
        }
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        DispatchQueue.main.async { self.results = [] }
    }
}

// =====================================================
// MARK: - Guardar Casa/Trabajo (AppStorage)
// =====================================================
private struct SavedPlace: Codable {
    let name: String
    let lat: Double
    let lon: Double
}

private enum FavoriteKind: String, Identifiable {
    case home, work
    var id: String { rawValue }
    var title: String { self == .home ? "Casa" : "Trabajo" }
    var icon: String { self == .home ? "house.fill" : "briefcase.fill" }
}

private func encodeSavedPlace(_ place: SavedPlace) -> String {
    let data = try? JSONEncoder().encode(place)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
}

private func decodeSavedPlace(_ str: String) -> SavedPlace? {
    guard let data = str.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(SavedPlace.self, from: data)
}

// =====================================================
// MARK: - Sheet para configurar Casa/Trabajo
// =====================================================
private struct FavoriteSetupSheet: View {
    let kind: FavoriteKind
    let initialRegion: MKCoordinateRegion?
    let onSave: (FavoriteKind, MKMapItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var completer = PlacesCompleter()
    @State private var q: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Buscar para guardar \(kind.title)…", text: $q)
                    .textInputAutocapitalization(.words)
                    .padding(12)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .padding(.horizontal, 16)
                    .onChange(of: q) { _, v in
                        completer.update(query: v, region: initialRegion)
                    }

                List {
                    ForEach(completer.results, id: \.self) { r in
                        Button {
                            Task { @MainActor in
                                let req = MKLocalSearch.Request(completion: r)
                                if let region = initialRegion { req.region = region }
                                do {
                                    let resp = try await MKLocalSearch(request: req).start()
                                    if let item = resp.mapItems.first {
                                        onSave(kind, item)
                                        dismiss()
                                    }
                                } catch { }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.title).font(.system(size: 15, weight: .semibold))
                                if !r.subtitle.isEmpty {
                                    Text(r.subtitle).font(.system(size: 12)).opacity(0.8)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Configurar \(kind.title)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }
}

// =====================================================
// MARK: - Side Button (CarPlay-like)
// =====================================================
struct SideButton: View {
    let icon: String
    let title: String
    let selected: Bool
    var showTitle: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: showTitle ? 6 : 0) {
                AppIconGlyph(systemName: icon, selected: selected)
                    .frame(width: 64, height: 64)

                if showTitle {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.9)
                }
            }
            .frame(width: 67, height: showTitle ? 77 : 65)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

private struct AppIconGlyph: View {
    let systemName: String
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.primary.opacity(selected ? 0.18 : 0.10), lineWidth: 1)
                )
                .shadow(color: .black.opacity(selected ? 0.18 : 0.10), radius: 10, x: 0, y: 6)

            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)
                .opacity(selected ? 1.0 : 0.95)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.00)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.softLight)
        )
    }
}

// =====================================================
// MARK: - Home (8 botones)
// =====================================================
struct HomePanel: View {
    let hasSidebar: Bool
    @Binding var keepScreenOn: Bool
    @AppStorage("appTheme") private var appTheme: String = "system"

    private let cols = [
        GridItem(.flexible(), spacing: CarPlayUI.homeGridSpacing),
        GridItem(.flexible(), spacing: CarPlayUI.homeGridSpacing),
        GridItem(.flexible(), spacing: CarPlayUI.homeGridSpacing),
        GridItem(.flexible(), spacing: CarPlayUI.homeGridSpacing)
    ]

    var body: some View {
        GeometryReader { geo in
            let available = geo.size.height
            let tileHeight = (available - CarPlayUI.homeGridSpacing) / CarPlayUI.homeRows

            ZStack {
                RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    )

                HomeGrid(
                    cols: cols,
                    themeTitle: themeTitle(),
                    keepScreenOn: $keepScreenOn,
                    tileHeight: tileHeight,
                    open: open(url:),
                    toggleTheme: toggleTheme,
                    openBluetoothOrSettings: openBluetoothOrSettings
                )
                .padding(18)
            }
            .padding(.leading, hasSidebar ? 24 : 0)
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func open(url: String) {
        guard let u = URL(string: url) else { return }
        if UIApplication.shared.canOpenURL(u) {
            UIApplication.shared.open(u)
        } else if let s = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(s)
        }
    }

    private func openBluetoothOrSettings() {
        let candidates = [
            "App-Prefs:Bluetooth",
            "App-Prefs:root=Bluetooth",
            UIApplication.openSettingsURLString
        ]
        for c in candidates {
            if let u = URL(string: c), UIApplication.shared.canOpenURL(u) {
                UIApplication.shared.open(u)
                return
            }
        }
    }

    private func toggleTheme() {
        switch appTheme {
        case "system": appTheme = "dark"
        case "dark": appTheme = "light"
        default: appTheme = "system"
        }
    }

    private func themeTitle() -> String {
        switch appTheme {
        case "dark": return "Modo claro"
        case "light": return "Modo sistema"
        default: return "Modo oscuro"
        }
    }
}

private struct HomeGrid: View {
    let cols: [GridItem]
    let themeTitle: String
    @Binding var keepScreenOn: Bool
    let tileHeight: CGFloat

    let open: (String) -> Void
    let toggleTheme: () -> Void
    let openBluetoothOrSettings: () -> Void

    var body: some View {
        LazyVGrid(columns: cols, spacing: CarPlayUI.homeGridSpacing) {
            HomeTile(title: "Tiempo", icon: "cloud.sun.fill", height: tileHeight) { open("weather://") }
            HomeTile(title: "WhatsApp", icon: "message.fill", height: tileHeight) { open("whatsapp://") }
            HomeTile(title: "Dispositivos", icon: "dot.radiowaves.left.and.right", height: tileHeight) { openBluetoothOrSettings() }
            HomeTile(title: "Spotify", icon: "music.note", height: tileHeight) { open("spotify://") }
            HomeTile(title: themeTitle, icon: "circle.lefthalf.filled", height: tileHeight) { toggleTheme() }
            HomeTile(title: "Calendario", icon: "calendar", height: tileHeight) { open("calshow:") }

            HomeTile(
                title: keepScreenOn ? "Pantalla ON" : "Pantalla OFF",
                icon: keepScreenOn ? "lock.open.fill" : "lock.fill",
                height: tileHeight
            ) { keepScreenOn.toggle() }

            HomeTile(title: "Salir", icon: "xmark.circle.fill", height: tileHeight) { open(UIApplication.openSettingsURLString) }
        }
    }
}

private struct HomeTile: View {
    let title: String
    let icon: String
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)

                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .frame(height: max(CarPlayUI.homeTileMinHeight, height))
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

// =====================================================
// MARK: - Contacts
// =====================================================
final class ContactsManager: ObservableObject {
    @Published var contacts: [CNContact] = []
    @Published var isAuthorized: Bool = false

    private let store = CNContactStore()

    func requestAccessAndFetch() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            isAuthorized = true
            fetchContacts()
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, _ in
                DispatchQueue.main.async {
                    self.isAuthorized = granted
                    if granted { self.fetchContacts() }
                }
            }
        default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.contacts = []
            }
        }
    }

    private func fetchContacts() {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        DispatchQueue.global(qos: .userInitiated).async {
            var fetched: [CNContact] = []
            do {
                try self.store.enumerateContacts(with: request) { contact, _ in
                    if !contact.phoneNumbers.isEmpty { fetched.append(contact) }
                }
            } catch { }

            DispatchQueue.main.async {
                self.contacts = fetched
            }
        }
    }
}

struct ContactsPanel: View {
    @ObservedObject var contactsManager: ContactsManager
    @Binding var query: String

    private var filtered: [CNContact] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return contactsManager.contacts }

        return contactsManager.contacts.filter { c in
            let name = "\(c.givenName) \(c.familyName)".lowercased()
            let phone = c.phoneNumbers.first?.value.stringValue.lowercased() ?? ""
            return name.contains(q) || phone.contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if !contactsManager.isAuthorized {
                VStack(spacing: 12) {
                    Text("Necesito permiso para mostrar tus contactos.")
                        .font(.system(size: 16, weight: .semibold))

                    Button("Dar permiso") {
                        contactsManager.requestAccessAndFetch()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.top, 10)

                Spacer(minLength: 0)

            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered, id: \.identifier) { c in
                            ContactRow(contact: c)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { contactsManager.requestAccessAndFetch() }
    }
}

private struct ContactRow: View {
    let contact: CNContact

    private var displayName: String {
        let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? "Sin nombre" : full
    }

    private var rawPhone: String? {
        contact.phoneNumbers.first?.value.stringValue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .semibold))

                    Text(rawPhone ?? "Sin teléfono")
                        .font(.system(size: 13))
                        .opacity(0.85)
                }

                Spacer()

                HStack(spacing: 10) {
                    actionButton("phone.fill") { call() }
                    actionButton("message.fill") { sms() }
                    actionButton("whatsapp") { whatsapp() }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func actionButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if systemImage == "whatsapp" {
                Text("WA")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .buttonStyle(.plain)
    }

    private func normalizedESPhone(_ input: String) -> String {
        let digits = input.replacingOccurrences(of: "+", with: "").filter { $0.isNumber }
        if digits.hasPrefix("34") { return "+\(digits)" }
        if digits.count == 9 { return "+34\(digits)" }
        return "+\(digits)"
    }

    private func call() {
        guard let rawPhone else { return }
        let phone = normalizedESPhone(rawPhone).replacingOccurrences(of: "+", with: "")
        if let url = URL(string: "tel://\(phone)") { UIApplication.shared.open(url) }
    }

    private func sms() {
        guard let rawPhone else { return }
        let phone = normalizedESPhone(rawPhone).replacingOccurrences(of: "+", with: "")
        if let url = URL(string: "sms:\(phone)") { UIApplication.shared.open(url) }
    }

    private func whatsapp() {
        guard let rawPhone else { return }
        let phone = normalizedESPhone(rawPhone).replacingOccurrences(of: "+", with: "")
        if let url = URL(string: "https://wa.me/\(phone)") { UIApplication.shared.open(url) }
    }
}

// =====================================================
// MARK: - Calendar
// =====================================================
struct AppCalendarEventRow: Identifiable {
    let id = UUID()
    let title: String
    let startDate: Date
    let isAllDay: Bool
    let location: String?
    let calendarColor: Color
}

final class AppCalendarManager: ObservableObject {
    @Published var isAuthorized: Bool = false
    @Published var upcoming: [AppCalendarEventRow] = []

    private let store = EKEventStore()
    private var isRequestingAccess: Bool = false

    func requestAccessAndFetch() {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .authorized:
            DispatchQueue.main.async {
                self.isAuthorized = true
                self.fetchToday()
            }

        case .notDetermined:
            guard !isRequestingAccess else { return }
            isRequestingAccess = true
            store.requestAccess(to: .event) { [weak self] granted, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRequestingAccess = false
                    self.isAuthorized = granted
                    if granted { self.fetchToday() } else { self.upcoming = [] }
                }
            }

        default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.upcoming = []
            }
        }
    }

    private func fetchToday() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? Date().addingTimeInterval(86400)

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        self.upcoming = events.prefix(10).map { ev in
            AppCalendarEventRow(
                title: ev.title ?? "Evento",
                startDate: ev.startDate,
                isAllDay: ev.isAllDay,
                location: ev.location,
                calendarColor: Color(ev.calendar.cgColor)
            )
        }

    }
}

struct CalendarWidget: View {
    @ObservedObject var calendarManager: AppCalendarManager

    private var todaysEvents: [AppCalendarEventRow] {
        calendarManager.upcoming.filter { Calendar.current.isDateInToday($0.startDate) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !calendarManager.isAuthorized {
                Text("Permite acceso al Calendario para ver tus eventos.")
                    .font(.system(size: 14))
                    .opacity(0.85)

            } else if todaysEvents.isEmpty {
                Text("No hay eventos programados para hoy")
                    .font(.system(size: 14))
                    .opacity(0.85)

            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(todaysEvents) { ev in
                            Button { openInCalendar(ev.startDate) } label: {
                                HStack(spacing: 12) {

                                    // ✅ Línea vertical del color del calendario
                                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                                        .fill(ev.calendarColor)
                                        .frame(width: 4)
                                        .frame(maxHeight: .infinity)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(ev.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .lineLimit(1)

                                        Text(eventSubtitle(ev))
                                            .font(.system(size: 12))
                                            .opacity(0.85)
                                            .lineLimit(1)
                                    }

                                    Spacer(minLength: 0)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.ultraThinMaterial)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }

                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func openInCalendar(_ date: Date) {
        let interval = date.timeIntervalSinceReferenceDate
        if let url = URL(string: "calshow:\(interval)") { UIApplication.shared.open(url) }
    }

    private func eventSubtitle(_ ev: AppCalendarEventRow) -> String {
        if ev.isAllDay {
            if let loc = ev.location, !loc.isEmpty { return "Todo el día · \(loc)" }
            return "Todo el día"
        } else {
            let t = shortTime(ev.startDate)
            if let loc = ev.location, !loc.isEmpty { return "\(t) · \(loc)" }
            return t
        }
    }

    private func shortTime(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_ES")
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}

// =====================================================
// MARK: - Status bar
// =====================================================
final class DeviceStatus: ObservableObject {
    @Published var isOnWiFi: Bool = false
    @Published var isOnCellular: Bool = false
    @Published var isOnline: Bool = true
    @Published var batteryLevel: Int = 100
    @Published var isCharging: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "DeviceStatus.NWPathMonitor")

    init() {
        startNetworkMonitoring()
        startBatteryMonitoring()
        refreshBattery()
    }

    deinit {
        monitor.cancel()
        UIDevice.current.isBatteryMonitoringEnabled = false
        NotificationCenter.default.removeObserver(self)
    }

    private func startNetworkMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isOnline = (path.status == .satisfied)
                self.isOnWiFi = path.usesInterfaceType(.wifi)
                self.isOnCellular = path.usesInterfaceType(.cellular)
            }
        }
        monitor.start(queue: queue)
    }

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(batteryChanged),
                                               name: UIDevice.batteryLevelDidChangeNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(batteryChanged),
                                               name: UIDevice.batteryStateDidChangeNotification,
                                               object: nil)
    }

    @objc private func batteryChanged() { refreshBattery() }

    private func refreshBattery() {
        let level = UIDevice.current.batteryLevel
        if level >= 0 { batteryLevel = Int(round(level * 100)) }
        let state = UIDevice.current.batteryState
        isCharging = (state == .charging || state == .full)
    }

    func batterySymbolName() -> String {
        let lvl = batteryLevel
        let base: String
        switch lvl {
        case 0...9: base = "battery.0"
        case 10...34: base = "battery.25"
        case 35...59: base = "battery.50"
        case 60...84: base = "battery.75"
        default: base = "battery.100"
        }
        return isCharging ? "\(base).bolt" : base
    }

    func connectionSymbolName() -> String {
        if !isOnline { return "wifi.exclamationmark" }
        if isOnWiFi { return "wifi" }
        if isOnCellular { return "antenna.radiowaves.left.and.right" }
        return "network"
    }
}

struct SideStatusBar: View {
    @StateObject private var status = DeviceStatus()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    var body: some View {
        VStack(spacing: 6) {
            Text(timeString(now))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)

            HStack(spacing: 6) {
                Image(systemName: status.connectionSymbolName())
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(0.95)

                Image(systemName: status.batterySymbolName())
                    .font(.system(size: 14, weight: .semibold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.primary)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .onReceive(timer) { _ in now = Date() }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

// =====================================================
// MARK: - Location
// =====================================================
final class AppLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = nil
    @Published var heading: CLLocationDirection? = nil

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.headingFilter = 1
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
    }
}

// Keyboard helper
private func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                    to: nil, from: nil, for: nil)
}

// =====================================================
// MARK: - Now Playing (PRO / limpio)
// =====================================================
final class NowPlayingManager: ObservableObject {
    @Published var title: String = "Nada reproduciéndose"
    @Published var subtitle: String = "Pon música en Spotify/Apple Music"
    @Published var isPlaying: Bool = false
    @Published var artworkImage: UIImage? = nil
    @Published var elapsed: TimeInterval = 0
    @Published var duration: TimeInterval = 0

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var timer: Timer?

    func start() {
        stop()

        player.beginGeneratingPlaybackNotifications()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlayerChanged),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: player
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlayerChanged),
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: player
        )

        // refresco (Spotify/terceros a veces no notifican bien el elapsed)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(self)
        player.endGeneratingPlaybackNotifications()
    }

    @objc private func handlePlayerChanged() {
        refresh()
    }

    private func refresh() {
        let item = player.nowPlayingItem
        let state = player.playbackState

        DispatchQueue.main.async {
            self.isPlaying = (state == .playing)

            // 1) Apple Music / sistema
            if let item {
                self.title = item.title ?? "Reproduciendo…"
                self.subtitle = item.artist ?? item.albumTitle ?? ""

                if let artwork = item.artwork {
                    self.artworkImage = artwork.image(at: CGSize(width: 500, height: 500))
                } else {
                    self.artworkImage = nil
                }

                self.duration = max(0, item.playbackDuration)
                self.elapsed = max(0, self.player.currentPlaybackTime)
                return
            }

            // 2) Fallback: NowPlayingInfoCenter (a veces trae Spotify)
            if let info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                let t = info[MPMediaItemPropertyTitle] as? String ?? ""
                let artist = info[MPMediaItemPropertyArtist] as? String ?? ""
                let album = info[MPMediaItemPropertyAlbumTitle] as? String ?? ""

                self.title = t.isEmpty ? (self.isPlaying ? "Reproduciendo…" : "En pausa") : t
                self.subtitle = !artist.isEmpty ? artist : album

                if let artwork = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork {
                    self.artworkImage = artwork.image(at: CGSize(width: 500, height: 500))
                } else {
                    self.artworkImage = nil
                }

                self.elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval ?? 0
                self.duration = info[MPMediaItemPropertyPlaybackDuration] as? TimeInterval ?? 0
                return
            }

            // 3) Nada
            self.title = "Nada reproduciéndose"
            self.subtitle = "Pon música en Spotify/Apple Music"
            self.artworkImage = nil
            self.elapsed = 0
            self.duration = 0
        }
    }
}

final class MediaControl: ObservableObject {
    private let player = MPMusicPlayerController.systemMusicPlayer
    func previous() { player.skipToPreviousItem() }
    func next() { player.skipToNextItem() }
    func togglePlayPause() {
        if player.playbackState == .playing { player.pause() }
        else { player.play() }
    }
}

// ✅ Card RIGHT COLUMN pro (sin cabecera, carátula grande)
struct RightNowPlayingCard: View {
    @StateObject private var np = NowPlayingManager()
    @StateObject private var media = MediaControl()

    var body: some View {
        VStack(spacing: 12) {

            // ▶️ Carátula pequeña + textos (como antes)
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 76, height: 76)

                    if let img = np.artworkImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Image(systemName: np.isPlaying ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .opacity(0.75)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(np.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)

                    Text(np.subtitle.isEmpty ? (np.isPlaying ? "En reproducción" : "En pausa") : np.subtitle)
                        .font(.system(size: 13))
                        .opacity(np.subtitle.isEmpty ? 0.6 : 0.85)
                        .lineLimit(1)
                }

                Spacer()
            }

            // ▶️ Progreso (solo si hay duración)
            if np.duration > 1 {
                VStack(spacing: 6) {
                    ProgressView(
                        value: min(max(np.elapsed, 0), np.duration),
                        total: np.duration
                    )
                    .progressViewStyle(.linear)
                    .tint(.primary)
                    .opacity(0.9)

                    HStack {
                        Text(timeString(np.elapsed))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .opacity(0.75)

                        Spacer()

                        Text(timeString(np.duration))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .opacity(0.60)
                    }
                }
            }

            // ▶️ Controles
            HStack(spacing: 12) {
                musicBtn("backward.fill") { media.previous() }

                musicBtn(np.isPlaying ? "pause.fill" : "play.fill") {
                    media.togglePlayPause()
                }
                .frame(maxWidth: .infinity)

                musicBtn("forward.fill") { media.next() }
            }
        }
        .onAppear { np.start() }
        .onDisappear { np.stop() }
    }

    // MARK: - Helpers

    private func musicBtn(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .frame(height: 44)
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }
}


// =====================================================
// MARK: - Route guidance sidebar
// =====================================================
struct RouteGuidanceSidebar: View {
    let instruction: String
    let iconName: String
    let stepIndex: Int
    let totalSteps: Int
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("En ruta")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.75)

                Spacer()

                Text("\(stepIndex + 1)/\(totalSteps)")
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.55)
            }

            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 26, weight: .semibold))
                    .frame(width: 34)
                    .opacity(0.95)

                Text(instruction.isEmpty ? "Continúa" : instruction)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3)
            }

            Button("Finalizar ruta") { onEnd() }
                .font(.system(size: 13, weight: .semibold))
                .buttonStyle(.bordered)
        }
    }
}

// =====================================================
// MARK: - MKPolyline helper
// =====================================================
private extension MKPolyline {
    var coordinates: [CLLocationCoordinate2D] {
        var coords = Array(repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
import WeatherKit

@MainActor
final class WeatherManager: ObservableObject {
    struct Snapshot {
        let symbolName: String
        let temp: String
        let condition: String
        let locationName: String
    }

    @Published var snapshot: Snapshot = .init(
        symbolName: "cloud.sun.fill",
        temp: "--°",
        condition: "Cargando…",
        locationName: "Ubicación"
    )

    private let service = WeatherService.shared
    private let geocoder = CLGeocoder()

    private var lastCoord: CLLocationCoordinate2D?
    private var task: Task<Void, Never>?

    func updateIfNeeded(coord: CLLocationCoordinate2D) {
        if let last = lastCoord {
            let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if d < 800 { return } // 800m
        }
        lastCoord = coord
        fetch(coord: coord)
    }

    func forceRefresh(coord: CLLocationCoordinate2D) {
        lastCoord = coord
        fetch(coord: coord)
    }

    private func fetch(coord: CLLocationCoordinate2D) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }

            let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            let placeName = await reverseGeocodeName(loc)

            do {
                let weather = try await service.weather(for: loc)

                let tempC = weather.currentWeather.temperature.converted(to: .celsius).value
                let temp = "\(Int(tempC.rounded()))°"

                // ✅ COMPATIBLE iOS16+: símbolo viene de condition
                let condition = weather.currentWeather.condition
                let sym = condition.sfSymbolName
                let cond = condition.descriptionES

                self.snapshot = .init(
                    symbolName: sym,
                    temp: temp,
                    condition: cond,
                    locationName: placeName.isEmpty ? "Ubicación" : placeName
                )
            } catch {
                self.snapshot = .init(
                    symbolName: "exclamationmark.triangle.fill",
                    temp: "--°",
                    condition: "Sin datos",
                    locationName: placeName.isEmpty ? "Ubicación" : placeName
                )
            }
        }
    }

    private func reverseGeocodeName(_ loc: CLLocation) async -> String {
        await withCheckedContinuation { cont in
            geocoder.reverseGeocodeLocation(loc) { placemarks, _ in
                let pm = placemarks?.first
                let locality = pm?.locality
                let admin = pm?.administrativeArea
                let name = [locality, admin].compactMap { $0 }.joined(separator: ", ")
                cont.resume(returning: name)
            }
        }
    }
}
private extension WeatherCondition {
    var sfSymbolName: String {
        switch self {
        case .clear, .mostlyClear: return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .mostlyCloudy, .cloudy: return "cloud.fill"
        case .foggy, .haze: return "cloud.fog.fill"
        case .breezy, .windy: return "wind"
        case .drizzle: return "cloud.drizzle.fill"
        case .rain, .heavyRain: return "cloud.rain.fill"
        case .thunderstorms: return "cloud.bolt.rain.fill"
        case .snow, .blizzard: return "snowflake"
        case .sleet, .hail: return "cloud.hail.fill"
        default: return "cloud.fill"
        }
    }
}

private extension WeatherCondition {
    var descriptionES: String {
        switch self {
        case .clear: return "Despejado"
        case .mostlyClear: return "Poco nuboso"
        case .partlyCloudy: return "Parcialmente nuboso"
        case .mostlyCloudy: return "Muy nuboso"
        case .cloudy: return "Nublado"
        case .foggy: return "Niebla"
        case .haze: return "Bruma"
        case .windy: return "Viento"
        case .breezy: return "Brisa"
        case .drizzle: return "Llovizna"
        case .rain: return "Lluvia"
        case .heavyRain: return "Lluvia fuerte"
        case .thunderstorms: return "Tormenta"
        case .snow: return "Nieve"
        case .sleet: return "Aguanieve"
        case .hail: return "Granizo"
        case .blizzard: return "Ventisca"
        @unknown default: return "Tiempo"
        }
    }
}


final class LocationTimeManager: ObservableObject {
    @Published var timeString: String = "--:--"
    @Published var placeLabel: String = "Ubicación"

    private let geocoder = CLGeocoder()
    private var timer: Timer?
    private var lastCoord: CLLocationCoordinate2D?

    func start(with locationManager: AppLocationManager) {
        stop()

        // refresco de hora (cada 15s va sobrado)
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.updateTime()
        }

        // intenta geocodificar al inicio si ya hay coord
        if let c = locationManager.coordinate {
            updateZone(for: c)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func coordinateDidChange(_ coord: CLLocationCoordinate2D) {
        // evita geocodificar cada tick: solo si cambia “lo suficiente”
        if let last = lastCoord {
            let d = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
            if d < 500 { // 500m
                updateTime()
                return
            }
        }
        updateZone(for: coord)
    }

    private func updateZone(for coord: CLLocationCoordinate2D) {
        lastCoord = coord

        let loc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
        geocoder.reverseGeocodeLocation(loc) { [weak self] placemarks, _ in
            guard let self else { return }

            let pm = placemarks?.first
            let tz = pm?.timeZone ?? .current

            let locality = pm?.locality
            let admin = pm?.administrativeArea
            let name = [locality, admin].compactMap { $0 }.joined(separator: ", ")
            DispatchQueue.main.async {
                self.placeLabel = name.isEmpty ? "Ubicación" : name
                self.timeZone = tz
                self.updateTime()
            }
        }
    }

    private var timeZone: TimeZone = .current

    private func updateTime() {
        let df = DateFormatter()
        df.locale = Locale(identifier: "es_ES")
        df.timeZone = timeZone
        df.dateFormat = "HH:mm"
        timeString = df.string(from: Date())
    }
}
struct RightLocationTimeCard: View {
    @ObservedObject var tm: LocationTimeManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hora local")
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.70)

            Text(tm.timeString)
                .font(.system(size: 34, weight: .bold))
                .monospacedDigit()

            Text(tm.placeLabel)
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.75)
                .lineLimit(1)
        }
    }
}
// =====================================================
// MARK: - CarPlay-style Now Playing (Center Panel)
// =====================================================
struct CarPlayNowPlayingPanel: View {
    @StateObject private var np = NowPlayingManager()
    @StateObject private var media = MediaControl()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            background

            VStack(spacing: 18) {
                topRow
                scrubber
                mainControls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // mismo “techo”
            .padding(18) // mismo “suelo”
        }
        .onAppear { np.start() }
        .onDisappear { np.stop() }
    }
    private func timeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        let m = s / 60
        let r = s % 60
        return String(format: "%d:%02d", m, r)
    }

    // MARK: - Background (igual que paneles)
    private var background: some View {
        RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: CarPlayUI.panelCorner, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.20 : 0.10),
                    radius: 14, x: 0, y: 10)
    }

    // MARK: - Top row (Artwork + Titles)
    private var topRow: some View {
        HStack(spacing: 18) {
            artwork
                .frame(width: 230, height: 230)

            VStack(alignment: .leading, spacing: 10) {
                Text(np.title)
                    .font(.system(size: 26, weight: .bold))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)

                Text(subtitleText)
                    .font(.system(size: 16, weight: .semibold))
                    .opacity(0.70)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private var artwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.primary.opacity(0.08))

            if let img = np.artworkImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .clipped()
            } else {
                Image(systemName: np.isPlaying ? "speaker.wave.2.fill" : "music.note")
                    .font(.system(size: 52, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: .black.opacity(scheme == .dark ? 0.20 : 0.08),
                radius: 12, x: 0, y: 10)
    }

    private var subtitleText: String {
        if !np.subtitle.isEmpty { return np.subtitle }
        return np.isPlaying ? "En reproducción" : "En pausa"
    }

    // MARK: - Scrubber (barra avance)
    private var scrubber: some View {
        VStack(spacing: 8) {
            if np.duration > 1 {
                ProgressView(value: min(max(np.elapsed, 0), np.duration), total: np.duration)
                    .progressViewStyle(.linear)
                    .tint(.primary)
                    .opacity(0.95)

                HStack {
                    Text(timeString(np.elapsed))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .opacity(0.75)

                    Spacer()

                    Text(timeString(np.duration))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .opacity(0.55)
                }
            } else {
                HStack {
                    Text("Pon música en Spotify/Apple Music")
                        .font(.system(size: 13, weight: .semibold))
                        .opacity(0.55)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Main controls
    private var mainControls: some View {
        HStack(spacing: 16) {
            mainControl("backward.fill") { media.previous() }
            mainPlayPause { media.togglePlayPause() }
            mainControl("forward.fill") { media.next() }
        }
        .frame(height: 62)
    }

    private func mainControl(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 74, height: 62)
                .background(Color.primary.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func mainPlayPause(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 24, weight: .bold))
                .frame(width: 110, height: 62)
                .background(Color.primary.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}


struct RightWeatherCard: View {
    @ObservedObject var wm: WeatherManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tiempo")
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.70)

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: wm.snapshot.symbolName)
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .opacity(0.95)

                Text(wm.snapshot.temp)
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
            }

            Text(wm.snapshot.condition)
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.85)
                .lineLimit(1)

            Text(wm.snapshot.locationName)
                .font(.system(size: 13, weight: .semibold))
                .opacity(0.70)
                .lineLimit(1)
        }
    }
}
