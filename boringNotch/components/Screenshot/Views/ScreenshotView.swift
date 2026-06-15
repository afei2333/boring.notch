//
//  ScreenshotView.swift
//  boringNotch
//
//  Created by boringNotch on 2025.
//

import Defaults
import SwiftUI

struct ScreenshotView: View {
    @ObservedObject var viewModel = ScreenshotViewModel.shared
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !viewModel.hasPermission {
                    permissionBanner
                        .padding(.bottom, 12)
                }

                if viewModel.isCapturing && viewModel.countdownRemaining > 0 {
                    countdownView
                } else {
                    captureModeSection
                        .padding(.bottom, 14)

                    optionsSection
                        .padding(.bottom, 14)

                    if viewModel.lastCapturedImage != nil {
                        recentSection
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear {
            viewModel.refreshPermission()
        }
    }

    // MARK: - Permission Banner

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.yellow)
            Text("需要屏幕录制权限")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Spacer()
            Button("授权") {
                viewModel.requestPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.accentColor)
        }
        .padding(8)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Countdown

    private var countdownView: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 3)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.countdownRemaining) / CGFloat(max(viewModel.selectedDelay.rawValue, 1)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: viewModel.countdownRemaining)
                Text("\(viewModel.countdownRemaining)")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            Button("取消") {
                viewModel.cancelCapture()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    // MARK: - Capture Mode Grid

    private var captureModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("捕获模式")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "8e8e93"))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(ScreenshotCaptureMode.allCases) { mode in
                    CaptureModeCard(
                        mode: mode,
                        isSelected: viewModel.selectedCaptureMode == mode,
                        isAvailable: mode.isAvailable
                    ) {
                        if mode.isAvailable {
                            viewModel.selectedCaptureMode = mode
                            viewModel.startCapture()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Options Section

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                // Delay
                HStack(spacing: 8) {
                    Text("延时")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "8e8e93"))

                    HStack(spacing: 4) {
                        ForEach(ScreenshotDelayOption.allCases) { option in
                            OptionPill(
                                label: option.label,
                                isSelected: viewModel.selectedDelay == option
                            ) {
                                withAnimation(.smooth(duration: 0.15)) {
                                    viewModel.selectedDelay = option
                                }
                            }
                        }
                    }
                }

                // Output
                HStack(spacing: 8) {
                    Text("输出")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "8e8e93"))

                    HStack(spacing: 4) {
                        ForEach(ScreenshotOutputMode.allCases) { mode in
                            OptionPill(
                                label: mode.label,
                                isSelected: viewModel.selectedOutput == mode
                            ) {
                                withAnimation(.smooth(duration: 0.15)) {
                                    viewModel.selectedOutput = mode
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent Screenshot Section

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DividerLine()

            Text("刚截的图 · 已落入暂存架")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "8e8e93"))

            HStack(spacing: 14) {
                // Thumbnail
                if let image = viewModel.lastCapturedImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 84, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: "2c2c2e"))
                        .frame(width: 84, height: 56)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 22))
                                .foregroundStyle(Color(hex: "636366"))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                }

                // Actions
                HStack(spacing: 10) {
                    RecentActionButton(icon: "doc.on.doc", label: "复制") {
                        viewModel.copyLastScreenshot()
                    }
                    RecentActionButton(icon: "text.viewfinder", label: "OCR") {
                        // v2
                    }
                    RecentActionButton(icon: "square.and.arrow.up", label: "分享") {
                        if let url = viewModel.lastCapturedURL {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.writeObjects([url as NSPasteboardWriting])
                            NSSharingServicePicker(items: [url]).show(relativeTo: .zero, of: NSView(), preferredEdge: .minY)
                        }
                    }
                    RecentActionButton(icon: "trash", label: "删除") {
                        viewModel.deleteLastScreenshot()
                    }
                }
            }
        }
    }
}

// MARK: - Subviews

struct CaptureModeCard: View {
    let mode: ScreenshotCaptureMode
    let isSelected: Bool
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color(hex: "85b7eb") : Color(hex: "f5f5f7"))
                Text(mode.label)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color(hex: "cfe3f7") : Color(hex: "c7c7cc"))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isSelected
                    ? Color(hex: "378add").opacity(0.2)
                    : Color.white.opacity(0.06)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected
                            ? Color(hex: "378add").opacity(0.55)
                            : Color.white.opacity(0.1),
                        lineWidth: 0.5
                    )
            )
            .opacity(isAvailable ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
    }
}

struct OptionPill: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color(hex: "f5f5f7") : Color(hex: "8e8e93"))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(isSelected ? Color.white.opacity(0.1) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }
}

struct RecentActionButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 19))
                            .foregroundStyle(Color(hex: "c7c7cc"))
                    )
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "8e8e93"))
            }
        }
        .buttonStyle(.plain)
    }
}

struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(height: 0.5)
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}

#Preview {
    ScreenshotView()
        .environmentObject(BoringViewModel())
        .frame(width: 400, height: 300)
        .background(.black)
}
