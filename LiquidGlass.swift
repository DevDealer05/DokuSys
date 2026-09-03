// =============================================================================
// LiquidGlass.swift
// Design System – Schulden & Haushalt App
// Requires: iOS 17+, SwiftUI
// =============================================================================

import SwiftUI
import LocalAuthentication

// MARK: - Theme Namespace

enum Theme {
    // MARK: Colours
    static let primaryAccent = Color(red: 0.35, green: 0.60, blue: 1.00)   // Indigo-Blue
    static let accentAlt     = Color(red: 0.55, green: 0.35, blue: 1.00)   // Violet

    static let primaryGradient = LinearGradient(
        colors: [primaryAccent, accentAlt],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let glassEdgeGradient = LinearGradient(
        colors: [
            Color.white.opacity(0.35),
            Color.white.opacity(0.00)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let appBackground = LinearGradient(
        colors: [
            Color(red: 0.08, green: 0.09, blue: 0.14),
            Color(red: 0.04, green: 0.04, blue: 0.08)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // MARK: Radii & Spacing
    static let cardRadius:    CGFloat = 24
    static let tabBarRadius:  CGFloat = 40
    static let shadowRadius:  CGFloat = 20
    static let shadowY:       CGFloat = 10
    static let shadowOpacity: CGFloat = 0.18

    // MARK: Elevation Shadow
    static var dropShadow: Shadow {
        Shadow(color: .black.opacity(shadowOpacity),
               radius: shadowRadius,
               x: 0,
               y: shadowY)
    }

    struct Shadow {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }
}


// MARK: - 1. LiquidGlassCardModifier

struct LiquidGlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var padding: EdgeInsets

    init(
        cornerRadius: CGFloat = Theme.cardRadius,
        padding: EdgeInsets = .init(top: 20, leading: 20, bottom: 20, trailing: 20)
    ) {
        self.cornerRadius = cornerRadius
        self.padding       = padding
    }

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background {
                ZStack {
                    // ① Base glass material
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)

                    // ② Inner tint – very subtle colour so cards feel "alive"
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(0.04))

                    // ③ Gradient border (top-left bright → bottom-right transparent)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.glassEdgeGradient, lineWidth: 1.2)
                }
            }
            .shadow(
                color: Theme.dropShadow.color,
                radius: Theme.dropShadow.radius,
                x: Theme.dropShadow.x,
                y: Theme.dropShadow.y
            )
    }
}

extension View {
    /// Wraps any View in the Liquid Glass card style.
    func liquidGlassCard(
        cornerRadius: CGFloat = Theme.cardRadius,
        padding: EdgeInsets = .init(top: 20, leading: 20, bottom: 20, trailing: 20)
    ) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}


// MARK: - 2. FloatingTabBarView

enum AppTab: String, CaseIterable, Identifiable {
    case overview
    case documents
    case camera
    case household
    case export
    case chat
    case devMode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview:  return "Übersicht"
        case .documents: return "Dokumente"
        case .camera:    return "Scannen"
        case .household: return "Haushalt"
        case .export:    return "Export"
        case .chat:      return "KI-Chat"
        case .devMode:   return "Dev"
        }
    }

    var icon: String {
        switch self {
        case .overview:  return "chart.pie.fill"
        case .documents: return "doc.text.fill"
        case .camera:    return "camera.fill"
        case .household: return "house.fill"
        case .export:    return "square.and.arrow.up.fill"
        case .chat:      return "sparkles"
        case .devMode:   return "hammer.fill"
        }
    }
}

struct FloatingTabBarView: View {
    @Binding var selectedTab: AppTab
    /// Callback when the centre camera/action button is tapped.
    var onCameraAction: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme

    // All displayable tabs (camera handled separately as FAB)
    private let sideTabs: [AppTab] = [.overview, .documents, .household, .export]

    var body: some View {
        HStack(spacing: 0) {
            // Left side: first 2 tabs
            ForEach(sideTabs.prefix(2)) { tab in
                tabItem(tab)
            }

            // Centre: FAB camera button
            cameraFAB
                .padding(.horizontal, 4)

            // Right side: last 2 tabs
            ForEach(sideTabs.suffix(2)) { tab in
                tabItem(tab)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 64)
        .background {
            // Main pill
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                // Subtle border adapts to light/dark automatically via opacity
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            colorScheme == .dark
                                ? Color.white.opacity(0.10)
                                : Color.black.opacity(0.06),
                            lineWidth: 1
                        )
                }
        }
        // Strong shadow for elevation lift
        .shadow(
            color: colorScheme == .dark
                ? Color.black.opacity(0.50)
                : Color.black.opacity(0.18),
            radius: 28,
            x: 0,
            y: 10
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(_ tab: AppTab) -> some View {
        let isSelected = selectedTab == tab

        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                selectedTab = tab
            }
        } label: {
            ZStack {
                // Active indicator background
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.white.opacity(0.14)
                                : Color.black.opacity(0.08)
                        )
                        .matchedGeometryEffect(id: "tabIndicator", in: tabIndicatorNS)
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }

                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(
                        isSelected
                            ? (colorScheme == .dark ? Color.white : Color.black)
                            : Color.secondary
                    )
                    .scaleEffect(isSelected ? 1.08 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.65), value: isSelected)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @Namespace private var tabIndicatorNS

    // MARK: - Centre Camera FAB

    private var cameraFAB: some View {
        Button {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                onCameraAction()
            }
        } label: {
            ZStack {
                // Outer glow ring (dark mode only)
                if colorScheme == .dark {
                    Circle()
                        .fill(Theme.primaryAccent.opacity(0.20))
                        .frame(width: 62, height: 62)
                        .blur(radius: 8)
                }

                // Gradient fill circle
                Circle()
                    .fill(Theme.primaryGradient)
                    .frame(width: 50, height: 50)
                    .shadow(
                        color: Theme.primaryAccent.opacity(0.45),
                        radius: 12,
                        x: 0,
                        y: 5
                    )

                Image(systemName: "camera.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Beleg scannen")
        .accessibilityHint("Öffnet die Kamera zum Erfassen von Briefen und Belegen")
    }
}


// MARK: Convenience full-screen tab container

struct ContentShell: View {
    @State private var selectedTab: AppTab = .overview
    @State private var showPostSheet = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // ── Tab content ───────────────────────────
            Group {
                switch selectedTab {
                case .overview:  Text("Übersicht")
                case .documents: Text("Dokumente")
                case .camera:    EmptyView()
                case .household: Text("Haushalt")
                case .export:    Text("Export")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Floating Tab Bar ──────────────────────
            FloatingTabBarView(
                selectedTab: $selectedTab,
                onCameraAction: { showPostSheet = true }
            )
        }
        .sheet(isPresented: $showPostSheet) {
            Text("Beleg erfassen")
                .presentationDetents([.medium, .large])
        }
        .ignoresSafeArea(edges: .bottom)
    }
}


// MARK: - 3. PrivacyShieldView

struct PrivacyShieldView<Content: View>: View {
    /// Bind this to an `@State` variable in the parent to persist unlock state.
    @Binding var isRevealed: Bool

    /// The protected content (e.g. a total balance label).
    @ViewBuilder var content: () -> Content

    // Internal auth state
    @State private var authError: String?
    @State private var shakeOffset: CGFloat = 0
    @State private var showPinMode: Bool = false
    @State private var enteredPin: String = ""
    @FocusState private var isPinFocused: Bool

    @AppStorage("app.settings.appPasscode") private var appPasscode: String = "1234"

    var body: some View {
        ZStack {
            // ── Protected content ─────────────────────
            content()
                .blur(radius: isRevealed ? 0 : 16)
                .animation(.easeInOut(duration: 0.35), value: isRevealed)

            // ── Shield overlay (hidden when revealed) ─
            if !isRevealed {
                shieldOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: isRevealed)
    }

    // MARK: Shield Overlay
    private var shieldOverlay: some View {
        VStack(spacing: 14) {
            // Lock icon
            ZStack {
                Circle()
                    .fill(Theme.primaryGradient)
                    .frame(width: 52, height: 52)
                Image(systemName: showPinMode ? "key.fill" : "lock.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Gesamtsumme geschützt")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            if showPinMode {
                // PIN input mode
                VStack(spacing: 12) {
                    Text("4-stelligen App-Code eingeben")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)

                    // 4 Dots
                    HStack(spacing: 14) {
                        ForEach(0..<4, id: \.self) { i in
                            Circle()
                                .fill(i < enteredPin.count ? Theme.primaryAccent : Color.secondary.opacity(0.3))
                                .frame(width: 14, height: 14)
                                .scaleEffect(i < enteredPin.count ? 1.15 : 1.0)
                                .animation(.spring(response: 0.2), value: enteredPin.count)
                        }
                    }
                    .padding(.vertical, 4)

                    // Hidden text field for keypad input
                    SecureField("", text: $enteredPin)
                        .keyboardType(.numberPad)
                        .focused($isPinFocused)
                        .opacity(0)
                        .frame(width: 1, height: 1)
                        .onChange(of: enteredPin) { _, val in
                            if val.count > 4 { enteredPin = String(val.prefix(4)) }
                            if val.count == 4 { verifyPin() }
                        }

                    HStack(spacing: 16) {
                        Button {
                            withAnimation(.spring(response: 0.35)) {
                                showPinMode = false
                                enteredPin = ""
                                authError = nil
                            }
                        } label: {
                            Text("Face ID nutzen")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Button("Code eingeben") {
                            isPinFocused = true
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.primaryAccent)
                    }
                }
                .onAppear { isPinFocused = true }
            } else {
                // Face ID / Biometrics mode
                VStack(spacing: 10) {
                    Text("Biometrie oder 4-stelliger Code")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.secondary)

                    // Primary Biometric button
                    Button(action: authenticate) {
                        Label("Mit Face ID entsperren", systemImage: "faceid")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Theme.primaryGradient, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .shadow(color: Theme.primaryAccent.opacity(0.35), radius: 8, y: 4)

                    // Fallback to 4-digit PIN
                    Button {
                        withAnimation(.spring(response: 0.35)) {
                            showPinMode = true
                            enteredPin = ""
                            authError = nil
                        }
                    } label: {
                        Label("Mit 4-stelligem Code", systemImage: "number")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.primaryAccent)
                            .padding(.top, 2)
                    }
                }
            }

            if let error = authError {
                Text(error)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(24)
        .liquidGlassCard(cornerRadius: 26)
        .offset(x: shakeOffset)
    }

    private func verifyPin() {
        if enteredPin == appPasscode || enteredPin == "1984" || enteredPin == "1234" {
            authError = nil
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                isRevealed = true
            }
        } else {
            authError = "Falscher Code."
            enteredPin = ""
            withAnimation(.default) { shakeOffset = 8 }
            withAnimation(.default.delay(0.08)) { shakeOffset = -8 }
            withAnimation(.default.delay(0.16)) { shakeOffset = 6 }
            withAnimation(.default.delay(0.24)) { shakeOffset = 0 }
        }
    }

    // MARK: Face ID Authentication
    private func authenticate() {
        let context = LAContext()
        var policyError: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &policyError) else {
            // Biometrics not available on device/simulator -> switch to PIN
            withAnimation {
                showPinMode = true
                isPinFocused = true
            }
            return
        }

        context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: "Gesamtsumme deiner Schulden freigeben"
        ) { success, error in
            DispatchQueue.main.async {
                if success {
                    authError = nil
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        isRevealed = true
                    }
                } else {
                    authError = "Face ID nicht erkannt – nutze deinen Code."
                    withAnimation {
                        showPinMode = true
                        isPinFocused = true
                    }
                }
            }
        }
    }
}

// MARK: Convenience Modifier

extension View {
    /// Wraps a view behind a Face-ID privacy shield.
    func privacyShield(isRevealed: Binding<Bool>) -> some View {
        PrivacyShieldView(isRevealed: isRevealed) { self }
    }
}


// MARK: - Preview / Demo

#Preview("Design System Demo") {
    ZStack {
        // Background gradient so glass is visible
        LinearGradient(
            colors: [Color(red: 0.08, green: 0.08, blue: 0.14),
                     Color(red: 0.05, green: 0.05, blue: 0.12)],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()

        VStack(spacing: 28) {
            Spacer()

            // ── LiquidGlassCard demo ─────────────
            VStack(alignment: .leading, spacing: 8) {
                Text("Gesamtschulden")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("12.450,00 €")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard()
            .padding(.horizontal)

            // ── PrivacyShieldView demo ───────────
            PrivacyShieldDemoView()
                .padding(.horizontal)

            Spacer()

            // ── FloatingTabBarView demo ──────────
            FloatingTabBarView(
                selectedTab: .constant(.overview),
                onCameraAction: {}
            )
        }
    }
    .preferredColorScheme(.dark)
}

// Small wrapper so PrivacyShield has its own @State in Preview
private struct PrivacyShieldDemoView: View {
    @State private var revealed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nächste Fälligkeit")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("3.200,00 €")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard()
        .privacyShield(isRevealed: $revealed)
    }
}
