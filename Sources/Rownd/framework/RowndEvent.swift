//
//  File.swift
//  
//
//  Created by Matt Hamann on 3/20/24.
//

import Foundation
import AnyCodable
import Combine

public enum RowndEventType: String, Codable {
    case signInStarted = "sign_in_started"
    case signInCompleted = "sign_in_completed"
    case signInFailed = "sign_in_failed"
    case userUpdated = "user_updated"
    case signOut = "sign_out"
    case userData = "user_data"
    case userDataSaved = "user_data_saved"
    case verificationStarted = "verification_started"
    case verificationCompleted = "verification_completed"
    case hubLoadFailed = "hub_load_failed"
}

public struct RowndEvent: Codable {
    public var event: RowndEventType
    public var data: [String: AnyCodable?]?
}

extension RowndEvent {
    static func signInStarted(method: SignInType) -> RowndEvent {
        RowndEvent(event: .signInStarted, data: ["method": AnyCodable(method.rawValue)])
    }

    /// Server refusals carry their raw `status` as `reason` and server `reason` as `message`.
    static func signInFailed(method: SignInType, error: Error) -> RowndEvent {
        var data: [String: AnyCodable?] = ["method": AnyCodable(method.rawValue)]
        if let refusal = error as? SuperTokensSignInUpRefusedError {
            if let status = refusal.status {
                data["reason"] = AnyCodable(status)
            }
            if let reason = refusal.reason {
                data["message"] = AnyCodable(reason)
            }
        } else {
            data["message"] = AnyCodable(String(describing: error))
        }
        return RowndEvent(event: .signInFailed, data: data)
    }
}

public protocol RowndEventHandlerDelegate: AnyObject {
    func handleRowndEvent(_ event: RowndEvent)
}

@MainActor
class RowndEventEmitter {
    static private var cancellables = Set<AnyCancellable>()
    static private var signInCompletedAccessToken: String?

    static func emit(_ event: RowndEvent) {
        if event.event == .signInCompleted {
            // Check if the access token is already valid — if so, fire immediately
            // to avoid a race where the Combine subscription misses a value that's
            // already settled before the sink is attached.
            let authState = Context.currentContext.store.state.auth
            if authState.isAccessTokenValid {
                Self.notifySignInCompletedListeners(event, authState: authState)
                return
            }

            // Token not yet valid — subscribe and wait for it
            let subscription = Context.currentContext.store.subscribe { $0.auth.isAccessTokenValid }
            subscription.$current.sink { isAccessTokenValid in
                if isAccessTokenValid {
                    subscription.unsubscribe()
                    Self.notifySignInCompletedListeners(
                        event,
                        authState: Context.currentContext.store.state.auth
                    )
                }
            }.store(in: &Self.cancellables)
        } else {
            if event.event == .signOut {
                signInCompletedAccessToken = nil
            }
            Self.notifyListeners(event)
        }
    }

    private static func notifySignInCompletedListeners(_ event: RowndEvent, authState: AuthState) {
        guard let accessToken = authState.accessToken else { return }
        guard signInCompletedAccessToken != accessToken else { return }

        signInCompletedAccessToken = accessToken
        Self.notifyListeners(event)
    }

    private static func notifyListeners(_ event: RowndEvent) {
        Context.currentContext.eventListeners.forEach { listener in
            listener.handleRowndEvent(event)
        }
    }

    static func resetForTests() {
        cancellables.removeAll()
        signInCompletedAccessToken = nil
    }
}
