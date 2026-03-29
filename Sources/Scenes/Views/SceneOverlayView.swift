import SwiftUI

struct SceneOverlayView: View {
    @EnvironmentObject private var runner: SceneRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconColor)

                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()
            }

            if let sceneName = runner.currentSceneName {
                Text(sceneName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }

            if runner.totalSteps > 0 {
                Text("Step \(max(runner.currentStepIndex, 1)) of \(runner.totalSteps)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if let stepLabel = runner.currentStepLabel {
                Text(stepLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var titleText: String {
        switch runner.executionState {
        case .idle:
            return "Scenes"
        case .running:
            return "Running Scene"
        case .succeeded:
            return "Scene Complete"
        case .failed:
            return "Scene Failed"
        }
    }

    private var iconName: String {
        switch runner.executionState {
        case .idle:
            return "sparkles.rectangle.stack"
        case .running:
            return "arrow.trianglehead.2.clockwise"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
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
