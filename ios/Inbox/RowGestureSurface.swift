import SwiftUI
import UIKit

// Explicit gesture precedence avoids SwiftUI converting a held row into a tap
// while the surrounding scroll view is negotiating its own pan gesture.
struct RowGestureSurface: UIViewRepresentable {
    var tap: () -> Void
    var preview: () -> Void
    var moved: (CGFloat) -> Void
    var finished: (CGFloat) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hold(_:)))
        hold.minimumPressDuration = 0.4
        hold.allowableMovement = 12
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: hold)
        let swipe = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        swipe.delegate = context.coordinator
        view.addGestureRecognizer(hold)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(swipe)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: RowGestureSurface
        init(_ parent: RowGestureSurface) { self.parent = parent }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            if recognizer.state == .ended { parent.tap() }
        }
        @objc func hold(_ recognizer: UILongPressGestureRecognizer) {
            if recognizer.state == .began {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                parent.preview()
            }
        }
        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            let distance = recognizer.translation(in: recognizer.view).x
            switch recognizer.state {
            case .changed: parent.moved(distance)
            case .ended: parent.finished(distance)
            case .cancelled, .failed: parent.finished(0)
            default: break
            }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5 && velocity.x < 0
        }
    }
}
