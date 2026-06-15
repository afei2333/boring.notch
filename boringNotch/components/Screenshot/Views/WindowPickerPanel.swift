//
//  WindowPickerPanel.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import AppKit
import SwiftUI

@MainActor
final class WindowPickerPanel: NSPanel {
    private let onComplete: ((id: CGWindowID, name: String, app: String)?) -> Void
    private var selfRetainer: WindowPickerPanel?

    init(windows: [(id: CGWindowID, name: String, app: String)], onComplete: @escaping ((id: CGWindowID, name: String, app: String)?) -> Void) {
        self.onComplete = onComplete

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        selfRetainer = self
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        center()

        let hostingView = NSHostingView(rootView:
            WindowPickerView(windows: windows) { [weak self] selected in
                self?.close()
                self?.onComplete(selected)
                self?.selfRetainer = nil
            }
        )
        hostingView.frame = contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        contentView!.addSubview(hostingView)
    }

    override var canBecomeKey: Bool { true }
}

struct WindowPickerView: View {
    let windows: [(id: CGWindowID, name: String, app: String)]
    let onSelect: ((id: CGWindowID, name: String, app: String)?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选择窗口")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("取消") { onSelect(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(windows, id: \.id) { window in
                        Button {
                            onSelect(window)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "macwindow")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(window.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text(window.app)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 360, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
