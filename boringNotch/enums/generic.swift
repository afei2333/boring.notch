//
//  generic.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation
import Defaults

public enum Style {
    case notch
    case floating
}

public enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

public enum NotchState {
    case closed
    case open
}

public enum NotchViews {
    case home
    case shelf
    case screenshot
    case ai
    case apps
    case clipboard
    case stats
    case stocks
}

enum SettingsEnum {
    case general
    case about
    case charge
    case download
    case mediaPlayback
    case hud
    case shelf
    case extensions
}

enum DownloadIndicatorStyle: String, Defaults.Serializable {
    case progress = "Progress"
    case percentage = "Percentage"
}

enum DownloadIconStyle: String, Defaults.Serializable {
    case onlyAppIcon = "Only app icon"
    case onlyIcon = "Only download icon"
    case iconAndAppIcon = "Icon and app icon"
}

enum MirrorShapeEnum: String, Defaults.Serializable {
    case rectangle = "Rectangular"
    case circle = "Circular"
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "Match menubar height"
    case matchRealNotchSize = "Match real notch height"
    case custom = "Custom height"
}

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white = "White"
    case albumArt = "Match album art"
    case accent = "Accent color"
}

/// Idle pixel-animation style on camera-less (external) displays.
enum PixelAnimationStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
    case invader = "太空巡逻"
    case matrixRain = "数字雨"
    case gameOfLife = "生命游戏"
    case twinkle = "星光闪烁"
    case pixelPet = "像素萌宠"
    case snake = "贪吃蛇"
    case campfire = "温馨篝火"
    case aquarium = "像素水族馆"
    case shmup = "太空射击"
    case pong = "像素乒乓"
    case nyanCat = "彩虹猫"
    case dinoRun = "恐龙奔跑"
    case woodenFish = "电子木鱼"

    var id: String { rawValue }
}
