import Foundation
import Testing
@testable import InkstoneCore

@Suite("iCloud availability")
struct ICloudAvailabilityTests {

    private let container = URL(fileURLWithPath: "/Users/x/Library/Mobile Documents/iCloud~com~orris~inkstone")

    @Test("Everything present is available")
    func available() {
        #expect(
            ICloudAvailability.diagnose(isEntitled: true, isSignedIn: true, container: container)
                == .available(container)
        )
    }

    /// The regression this type exists for: a build with no entitlement resolves
    /// no container, and that must not be reported as anything about iCloud.
    @Test("An unentitled build is never blamed on the container")
    func unentitledIsNotUnreachable() {
        let result = ICloudAvailability.diagnose(isEntitled: false, isSignedIn: true, container: nil)
        #expect(result == .notEntitled)
        #expect(result != .unreachable)
    }

    /// Being signed out while unentitled is still an unentitled build: the
    /// binary could not have asked, so the account state is not the finding.
    @Test("Entitlement outranks the account state")
    func entitlementOutranksAccount() {
        #expect(
            ICloudAvailability.diagnose(isEntitled: false, isSignedIn: false, container: nil)
                == .notEntitled
        )
    }

    @Test("Signed out is the user's to fix")
    func signedOut() {
        #expect(
            ICloudAvailability.diagnose(isEntitled: true, isSignedIn: false, container: nil)
                == .notSignedIn
        )
    }

    /// Only when the build could ask and the account exists does a missing
    /// container mean the container.
    @Test("Unreachable needs both preconditions met")
    func unreachable() {
        #expect(
            ICloudAvailability.diagnose(isEntitled: true, isSignedIn: true, container: nil)
                == .unreachable
        )
    }

    @Test("Only availability permits creating a vault")
    func usability() {
        #expect(ICloudAvailability.available(container).isUsable)
        #expect(!ICloudAvailability.notEntitled.isUsable)
        #expect(!ICloudAvailability.notSignedIn.isUsable)
        #expect(!ICloudAvailability.unreachable.isUsable)
    }
}
