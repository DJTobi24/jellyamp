import SwiftUI

/// Public web pages referenced from the app and from the App Store listing
/// (`ios/fastlane/metadata/*/…_url.txt`). `scripts/check-appstore-metadata.py`
/// fails CI when the two drift apart.
enum AppLinks {
    static let privacyPolicy = URL(string: "https://djtobi24.github.io/jellyamp/privacy/")!
    static let support = URL(string: "https://djtobi24.github.io/jellyamp/support/")!
    static let sourceCode = URL(string: "https://github.com/DJTobi24/jellyamp")!
    static let issues = URL(string: "https://github.com/DJTobi24/jellyamp/issues")!
    static let jellyfin = URL(string: "https://jellyfin.org")!
}

/// Settings → About: version, legal links and license notices. Pushed onto
/// the Settings navigation stack, so it brings no `NavigationStack` itself.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                AboutHeader()
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Version", value: AppVersion.marketing)
                LabeledContent("Build", value: AppVersion.build)
            }

            Section {
                AboutLinkRow(title: "Privacy Policy", systemImage: "hand.raised", url: AppLinks.privacyPolicy)
                AboutLinkRow(title: "Help & Support", systemImage: "questionmark.circle", url: AppLinks.support)
                AboutLinkRow(title: "Report a Problem", systemImage: "exclamationmark.bubble", url: AppLinks.issues)
                AboutLinkRow(title: "Source Code", systemImage: "chevron.left.forwardslash.chevron.right", url: AppLinks.sourceCode)
            } footer: {
                Text("Jellyamp collects no data. It only talks to the servers you set up.")
            }

            Section {
                NavigationLink {
                    LicensesView()
                } label: {
                    Label("Licenses & Acknowledgements", systemImage: "doc.text")
                }
            } footer: {
                Text(
                    "Jellyamp is an independent open-source project. It is not affiliated with, endorsed by or sponsored by Jellyfin or Plex. Jellyfin is a trademark of the Jellyfin project; Plex and Plexamp are trademarks of Plex, Inc."
                )
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Version strings from Info.plist, which takes them from `MARKETING_VERSION`
/// / `CURRENT_PROJECT_VERSION` in `ios/project.yml`.
enum AppVersion {
    static var marketing: String { infoString("CFBundleShortVersionString") }
    static var build: String { infoString("CFBundleVersion") }

    private static func infoString(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? "–"
    }
}

private struct AboutHeader: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("AppLogo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .accessibilityHidden(true)
            Text("Jellyamp")
                .font(.title2.weight(.semibold))
            Text("A music player for your Jellyfin server")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 8)
    }
}

private struct AboutLinkRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let url: URL

    var body: some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityHint(Text("Opens in your browser"))
    }
}

/// License of the app itself plus everything that ships inside the binary.
struct LicensesView: View {
    var body: some View {
        List {
            Section {
                Text(LicenseText.jellyamp)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Jellyamp")
            } footer: {
                Text("Jellyamp is free software released under the MIT License.")
            }

            Section {
                Text(
                    "Jellyamp ships no third-party libraries or SDKs. The app and its JellyampCore, JellyfinBackend and SonicClient modules are part of this project and covered by the license above; everything else is provided by iOS."
                )
                .font(.footnote)
            } header: {
                Text("Third-Party Software")
            }

            Section {
                Text(
                    "Jellyamp connects to Jellyfin, the free software media system, through its public HTTP API. Thank you to everyone who builds and maintains it."
                )
                .font(.footnote)
                Link("jellyfin.org", destination: AppLinks.jellyfin)
            } header: {
                Text("Acknowledgements")
            }
        }
        .navigationTitle("Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Verbatim copy of the repository's `LICENSE` file, kept in source so it
/// needs no bundle resource. `scripts/check-appstore-metadata.py` compares the
/// two in CI.
enum LicenseText {
    static let jellyamp = """
        MIT License

        Copyright (c) 2026 DJTobi24

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """
}
