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

    @State private var serverURL: String = ServerConfig.baseURLString
    @State private var token: String = ""

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

    /// Formular-Spalte (rechts) — Eingabefelder + Anmelden auf der warmen Fläche.
    private var formPanel: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                Text(t("login.signIn"))
                    .font(BrandFont.serif(26, weight: .semibold))
                    .foregroundStyle(BrandColor.text)

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

                    Text(t("login.tokenHint"))
                        .font(BrandFont.sans(11))
                        .foregroundStyle(BrandColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
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
            }
            .frame(maxWidth: 360)
            .padding(48)
        }
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
