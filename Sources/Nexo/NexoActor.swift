//
//  NexoActor.swift
//  Nexo
//

import Foundation

// MARK: - NexoActor

/// Serial executor for all Nexo logic.
///
/// Keeps room state, chat, activities, transfers and identity work off the
/// main thread. The app hops back to main when it needs to publish UI
/// snapshots.
@globalActor
public actor NexoActor {
    public static let shared = NexoActor()
    private init() {}
}
