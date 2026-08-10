//
//  drop.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on  04/08/24.
//

import Foundation
import SwiftUI


public class BoringAnimations {
    @Published var notchStyle: Style = .notch
    
    init() {
        self.notchStyle = .notch
    }
    
    var animation: Animation {
        if #available(macOS 14.0, *), notchStyle == .notch {
            Animation.spring(.bouncy(duration: 0.4))
        } else {
            Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.7)
        }
    }
    
    // TODO: Move all animations to this file

}

/// The only place the open/close timing lives. Every path that flips
/// `notchState` routes through `BoringViewModel.open()/close()`, which apply
/// these — so the shape, the chin, the padding and the shadow all ride one
/// curve instead of three that settle at different times.
///
/// ponytail: these four numbers are the whole tuning surface. Feel is physical —
/// change them, don't add a fifth animation somewhere else.
enum NotchAnimation {
    /// Opening inflates: a little overshoot, like the island has mass.
    static let open = Animation.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0)
    /// Closing deflates: critically damped and quicker. A bounce on the way
    /// out is the single thing that makes a notch read as cheap.
    static let close = Animation.spring(response: 0.32, dampingFraction: 1.0, blendDuration: 0)
    /// Content appears *after* the container has room for it.
    static let contentIn = Animation.smooth(duration: 0.26).delay(0.07)
    /// Content leaves first, so the shape never shrinks through live text.
    static let contentOut = Animation.easeOut(duration: 0.1)
}
