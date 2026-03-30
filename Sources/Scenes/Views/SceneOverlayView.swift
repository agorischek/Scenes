import SwiftUI

struct SceneOverlayView: View {
    @EnvironmentObject private var runner: SceneRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                HStack(spacing: 10) {
                    statusIndicator

                    Text(titleText)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .contentTransition(.interpolate)
                }

                Spacer()

                Button {
                    runner.dismissOverlay()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(OverlayCloseButtonStyle())
            }

            if let sceneName = runner.currentSceneName {
                Text(sceneName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .contentTransition(.interpolate)
            }

            if runner.totalSteps > 0 {
                Text("Step \(max(runner.currentStepIndex, 1)) of \(runner.totalSteps)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentTransition(.interpolate)
            }

            if let stepLabel = runner.currentStepLabel {
                Text(stepLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.interpolate)
            }

            if runner.executionState == .running {
                HStack {
                    Spacer()

                    Button("Cancel") {
                        runner.cancelCurrentScene()
                    }
                    .buttonStyle(OverlayActionButtonStyle())
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.clear)
                .background(
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 20, y: 12)
        .animation(.spring(duration: 0.32), value: runner.executionState)
        .animation(.spring(duration: 0.32), value: runner.currentSceneName)
        .animation(.spring(duration: 0.32), value: runner.currentStepIndex)
        .animation(.spring(duration: 0.32), value: runner.currentStepLabel)
    }

    private var titleText: String {
        switch runner.executionState {
        case .idle:
            return "Scenes"
        case .running:
            return "Setting scene"
        case .succeeded:
            return "Scene Complete"
        case .failed:
            return "Scene Failed"
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch runner.executionState {
        case .idle:
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
        case .running:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .tint(iconColor)
                .frame(width: 16, height: 16)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .symbolEffect(.bounce, value: runner.executionState)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
        }
    }

    private var iconColor: Color {
        switch runner.executionState {
        case .idle:
            return .white.opacity(0.85)
        case .running:
            return Color(red: 0.76, green: 0.85, blue: 1.0)
        case .succeeded:
            return Color(red: 0.56, green: 0.90, blue: 0.60)
        case .failed:
            return Color(red: 1.0, green: 0.58, blue: 0.58)
        }
    }
}

private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

private struct OverlayActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.10))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}

private struct OverlayCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
    }
}
