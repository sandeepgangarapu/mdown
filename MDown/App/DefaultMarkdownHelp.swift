import SwiftUI

/// A quiet, on-demand tip. Reading it never changes the user's file associations.
struct DefaultMarkdownHelpButton: View {
    @AppStorage("mdown.didReadDefaultMarkdownHelp") private var hasReadHelp = false
    @State private var isPresented = false

    var body: some View {
        if !hasReadHelp {
            tipButton
                .onChange(of: isPresented) { wasPresented, presented in
                    if wasPresented && !presented {
                        hasReadHelp = true
                    }
                }
        }
    }

    private var tipButton: some View {
        Button {
            isPresented = true
        } label: {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Make MDown your default Markdown app")
        .accessibilityLabel("Make MDown your default Markdown app")
        .accessibilityHint("Shows instructions for opening Markdown files in MDown by default")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open Markdown in MDown")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 12) {
                    step(1, "In Finder, select a .md file and press ⌘I (Get Info).")
                    step(2, "Under Open with, choose MDown.")
                    step(3, "Click Change All… and confirm.")
                }
                .font(.callout)

                Text("Repeat for .markdown files if you use them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Got it") {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 310)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ instruction: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number).")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 14, alignment: .trailing)
            Text(instruction)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
