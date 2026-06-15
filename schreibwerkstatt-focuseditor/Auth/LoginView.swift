//
//  LoginView.swift
//  schreibwerkstatt-focuseditor
//
//  Anmeldung per Device-Token. Da der Client das Token nicht selbst
//  ausstellen kann (Server sperrt POST via Device-Token), gibt der User
//  Server-Adresse + Token aus dem Web-`/me`-Bereich ein. Das Token wird
//  validiert und in der Keychain abgelegt.
//

import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var loc: LocalizationController
    @Environment(\.openURL) private var openURL

    @State private var serverURL: String = ServerConfig.baseURLString
    @State private var token: String = ""
    @State private var showPrivacy = false

    private var isBusy: Bool { auth.state == .validating }
    private var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }

    var body: some View {
        GeometryReader { geo in
            // Zweispaltiges Hero-Layout füllt die Fensterbreite: links die
            // markierte Navy-Fläche, rechts das Formular. Bei schmalem Fenster
            // (< 720) fällt es auf eine einspaltige, zentrierte Ansicht zurück.
            if geo.size.width >= 720 {
                HStack(spacing: 0) {
                    heroPanel
                        .frame(width: max(300, geo.size.width * 0.42))
                    formPanel
                        .frame(maxWidth: .infinity)
                }
            } else {
                ZStack {
                    BrandColor.bg.ignoresSafeArea()
                    formPanel
                }
            }
        }
        .frame(minWidth: 640, minHeight: 460)
    }

    /// Markierte Hero-Spalte (links) — Navy-Verlauf mit Logo, Name, Tagline.
    private var heroPanel: some View {
        ZStack {
            LinearGradient(
                colors: [BrandColor.primary, BrandColor.primaryHover],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 88, height: 88)
                    .accessibilityLabel("Schreibwerkstatt")

                VStack(alignment: .leading, spacing: 10) {
                    Text("Schreibwerkstatt")
                        .font(BrandFont.serif(34, weight: .semibold))
                        .foregroundStyle(BrandColor.onPrimary)

                    Text(t("login.heroTagline"))
                        .font(BrandFont.sans(14))
                        .foregroundStyle(BrandColor.onPrimary.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 320, alignment: .leading)
                }
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Formular-Spalte (rechts) — Onboarding (Token-Flow), Eingabefelder,
    /// Anmelden und Datenschutz-Hinweis auf der warmen Fläche. In einer
    /// ScrollView, damit der erweiterte Inhalt auf niedrigen Fenstern nicht klippt.
    private var formPanel: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("login.signIn"))
                            .font(BrandFont.serif(26, weight: .semibold))
                            .foregroundStyle(BrandColor.text)
                        Text(t("login.subtitle"))
                            .font(BrandFont.sans(13))
                            .foregroundStyle(BrandColor.muted)
                        Text(t("login.requiresServer"))
                            .font(BrandFont.sans(12))
                            .foregroundStyle(BrandColor.subtle)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }

                    onboardingSteps

                    VStack(alignment: .leading, spacing: 14) {
                        field(title: t("login.serverAddress")) {
                            TextField("https://…", text: $serverURL)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .font(BrandFont.sans(13))
                        }

                        field(title: t("login.deviceToken")) {
                            SecureField("swd_…", text: $token)
                                .textFieldStyle(.roundedBorder)
                                .font(BrandFont.sans(13))
                                .onSubmit { submit() }
                        }
                    }

                    if let error = auth.lastError {
                        Text(error)
                            .font(BrandFont.sans(12))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button(action: submit) {
                        HStack(spacing: 8) {
                            if isBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(isBusy ? t("login.checking") : t("login.signIn"))
                                .font(BrandFont.sans(14, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(BrandColor.primary)
                    .disabled(!canSubmit)

                    privacyDisclosure
                }
                .frame(maxWidth: 360, alignment: .leading)
                .padding(48)
            }
        }
    }

    /// Token-Flow als nummerierte 3-Schritt-Anleitung mit direkten Links zur
    /// Registrierung (`/register`) und zur Token-Ausstellung (`#profil`,
    /// SPA-Hash-Route — die User-Settings-Karte enthält die Geräte-Tokens) auf
    /// dem im Feld stehenden Server. Macht den Copy-Paste-Login ohne Vorwissen
    /// begehbar.
    private var onboardingSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("login.howToTitle"))
                .font(BrandFont.sans(11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(BrandColor.subtle)

            stepRow(1, t("login.step1")) {
                Button(t("login.createAccount")) {
                    openURL(ServerConfig.pageURL(onServer: serverURL, path: "register"))
                }
                .buttonStyle(.link)
                .font(BrandFont.sans(12, weight: .medium))
            }
            stepRow(2, t("login.step2")) {
                Button(t("login.openTokenPage")) {
                    openURL(ServerConfig.pageURL(onServer: serverURL, fragment: "profil"))
                }
                .buttonStyle(.link)
                .font(BrandFont.sans(12, weight: .medium))
            }
            stepRow(3, t("login.step3"), button: { EmptyView() })
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(BrandColor.primary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func stepRow<B: View>(_ number: Int, _ text: String,
                                  @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(BrandFont.sans(11, weight: .bold))
                .foregroundStyle(BrandColor.primary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(BrandColor.primary.opacity(0.14)))

            VStack(alignment: .leading, spacing: 5) {
                Text(text)
                    .font(BrandFont.sans(12))
                    .foregroundStyle(BrandColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                button()
            }
        }
    }

    /// Datenschutz-Hinweis (in-app, keine externe URL) — beschreibt die
    /// Datenhaltung wahrheitsgemäss aus der Architektur: local-first, Token nur
    /// in der Keychain, keine Dritt-Übertragung. Eingeklappt, um das Formular
    /// schlank zu halten.
    private var privacyDisclosure: some View {
        DisclosureGroup(isExpanded: $showPrivacy) {
            VStack(alignment: .leading, spacing: 8) {
                Text(t("login.privacyBody"))
                    .font(BrandFont.sans(11))
                    .foregroundStyle(BrandColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Button(t("login.privacyShowFull")) {
                    openURL(ServerConfig.pageURL(onServer: serverURL, path: "datenschutz"))
                }
                .buttonStyle(.link)
                .font(BrandFont.sans(11, weight: .medium))
            }
            .padding(.top, 8)
        } label: {
            Text(t("login.privacyTitle"))
                .font(BrandFont.sans(12, weight: .medium))
                .foregroundStyle(BrandColor.subtle)
        }
        .tint(BrandColor.primary)
    }

    @ViewBuilder
    private func field<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(BrandFont.sans(11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(BrandColor.subtle)
            content()
        }
    }

    private func submit() {
        guard canSubmit else { return }
        Task {
            await auth.signIn(serverURLString: serverURL, rawToken: token)
            if auth.state == .signedIn { token = "" }
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthStore())
        .environmentObject(LocalizationController())
}
