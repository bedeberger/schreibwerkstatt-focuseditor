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

    @State private var serverURL: String = ServerConfig.baseURLString
    @State private var token: String = ""

    private var isBusy: Bool { auth.state == .validating }
    private var canSubmit: Bool {
        !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isBusy
    }

    var body: some View {
        ZStack {
            BrandColor.bg.ignoresSafeArea()

            VStack(spacing: 22) {
                header

                VStack(alignment: .leading, spacing: 14) {
                    field(title: "Server-Adresse") {
                        TextField("https://…", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                            .disableAutocorrection(true)
                            .font(BrandFont.sans(13))
                    }

                    field(title: "Gerätetoken") {
                        SecureField("swd_…", text: $token)
                            .textFieldStyle(.roundedBorder)
                            .font(BrandFont.sans(13))
                            .onSubmit { submit() }
                    }

                    Text("Stelle das Token in der Schreibwerkstatt unter „Mein Konto → Gerätetoken“ aus und füge es hier ein. Es wird nur einmal angezeigt.")
                        .font(BrandFont.sans(11))
                        .foregroundStyle(BrandColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 360)

                if let error = auth.lastError {
                    Text(error)
                        .font(BrandFont.sans(12))
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 360)
                }

                Button(action: submit) {
                    HStack(spacing: 8) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(isBusy ? "Prüfe …" : "Anmelden")
                            .font(BrandFont.sans(14, weight: .medium))
                    }
                    .frame(maxWidth: 360)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(BrandColor.primary)
                .disabled(!canSubmit)
            }
            .padding(40)
        }
        .frame(minWidth: 520, minHeight: 460)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 84, height: 84)
                .accessibilityLabel("Schreibwerkstatt")

            Text("Schreibwerkstatt")
                .font(BrandFont.serif(28, weight: .semibold))
                .foregroundStyle(BrandColor.text)

            Text("Anmelden, um deine Seiten zu synchronisieren.")
                .font(BrandFont.sans(13))
                .foregroundStyle(BrandColor.muted)
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
}
