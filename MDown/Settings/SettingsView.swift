import MDownCore
import SwiftUI

struct SettingsView: View {
    @AppStorage(MDownSettings.fontSize) private var fontSize = MDownSettings.defaultFontSize
    @AppStorage(MDownSettings.face) private var face: PageFace = MDownSettings.defaultFace
    @AppStorage(MDownSettings.theme) private var theme: PageTheme = MDownSettings.defaultTheme
    @AppStorage(MDownSettings.showWordCount) private var showWordCount = false
    @Environment(\.colorScheme) private var colorScheme

    private static let sample = MarkdownRenderModel.sourcedBlocks(from: """
    ## A quiet page
    Click any line to edit its **Markdown**, then press *Escape* to set it again.
    """)

    var body: some View {
        Form {
            Section {
                Picker("Font", selection: $face) {
                    ForEach(PageFace.allCases) { face in
                        Text(face.title).tag(face)
                    }
                }
                LabeledContent("Size") {
                    HStack(spacing: 10) {
                        Slider(value: $fontSize, in: MDownSettings.fontSizeRange, step: 1) {
                            Text("Size")
                        } minimumValueLabel: {
                            Image(systemName: "textformat.size.smaller")
                        } maximumValueLabel: {
                            Image(systemName: "textformat.size.larger")
                        }
                        .labelsHidden()
                        Text("\(Int(fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Picker("Page", selection: $theme) {
                    ForEach(PageTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Text")
            } footer: {
                preview
            }

            Section {
                Toggle("Show word count in the title bar", isOn: $showWordCount)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") {
                    fontSize = MDownSettings.defaultFontSize
                    face = MDownSettings.defaultFace
                    theme = MDownSettings.defaultTheme
                    showWordCount = false
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var preview: some View {
        let style = PageStyle(
            size: CGFloat(fontSize),
            face: face,
            colors: MDownPalette.colors(theme: theme, scheme: colorScheme)
        )
        return MarkdownPage(blocks: Self.sample, style: style, baseDirectory: nil)
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: style.colors.page), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator)
            }
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preview")
    }
}
