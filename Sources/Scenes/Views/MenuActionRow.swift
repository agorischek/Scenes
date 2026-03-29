import SwiftUI

struct MenuActionRow: View {
    let title: String
    let systemImage: String
    var isEnabled = true
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 14)

                Text(title)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(background)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .padding(.horizontal, -8)
        .padding(.vertical, -1)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isHovered && isEnabled ? Color.white.opacity(0.10) : Color.clear)
    }
}
