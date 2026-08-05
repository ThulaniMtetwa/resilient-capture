import Foundation

/// A small, user-facing status line derived from queue + network state.
///
/// Pure data (no SwiftUI types) so it's computed in the model and unit-testable;
/// the view maps `tone` to colour and `showsActivity` to a spinner.
struct StatusMessage: Equatable, Sendable {
    enum Tone: Sendable { case info, success, warning, offline }

    let text: String
    let systemImage: String
    let tone: Tone
    /// When true, show a spinner instead of the icon (work in progress).
    var showsActivity: Bool = false
}
