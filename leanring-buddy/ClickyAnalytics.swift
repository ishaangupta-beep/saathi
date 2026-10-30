//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  Saathi sends no analytics. These are no-op stubs that keep Clicky's
//  original call sites compiling without the PostHog package.
//

import Foundation

enum ClickyAnalytics {
    static func configure() {}
    static func trackAppOpened() {}
    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingVideoCompleted() {}
    static func trackOnboardingDemoTriggered() {}
    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}
    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}
    static func trackResponseError(error: String) {}
    static func trackTTSError(error: String) {}
}
