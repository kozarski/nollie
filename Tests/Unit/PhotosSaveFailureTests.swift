#if os(iOS)
import Foundation
import Photos
import Testing
@testable import Nollie

/// The picture viewer's message when Save to Photos fails (on the Mac, saving goes to Downloads).
@Suite struct PhotosSaveFailureTests {
    private let denied = PHPhotosError.Code.accessUserDenied
    private let restricted = PHPhotosError.Code.accessRestricted

    @Test(arguments: [PHPhotosError.Code.accessUserDenied, .accessRestricted])
    func photosOwnAccessErrorMeansAccessIsOffAndSettingsIsOffered(code: PHPhotosError.Code) {
        let failure = PhotoSaveFailure(PHPhotosError(code), addOnly: .notDetermined)
        #expect(failure.accessOff && failure.message == PhotoSaveFailure.accessOffMessage)
        // The same error can arrive wrapped as a plain NSError.
        let wrapped = NSError(domain: PHPhotosErrorDomain, code: code.rawValue)
        #expect(PhotoSaveFailure(wrapped, addOnly: .authorized).accessOff)
    }

    @Test(arguments: [PHAuthorizationStatus.denied, .restricted])
    func aDeniedAccessStatusIsEnoughWhateverTheErrorWas(status: PHAuthorizationStatus) {
        // Photos does not always refuse with its access error, so the status speaks too.
        let unrelated = NSError(domain: PHPhotosErrorDomain, code: -1)
        #expect(PhotoSaveFailure(unrelated, addOnly: status) == PhotoSaveFailure(message: PhotoSaveFailure.accessOffMessage, accessOff: true))
    }

    @Test(arguments: [PHAuthorizationStatus.authorized, .limited, .notDetermined])
    func anyOtherFailureSaysWhatHappenedAndOffersNoSettings(status: PHAuthorizationStatus) {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
                            userInfo: [NSLocalizedDescriptionKey: "That file has gone."])
        let failure = PhotoSaveFailure(error, addOnly: status)
        #expect(failure.accessOff == false)
        #expect(failure.message.hasPrefix("Photos could not keep it: ") && failure.message.hasSuffix("That file has gone."))
    }

    @Test func aDifferentPhotosErrorIsNotMistakenForAccessBeingOff() {
        #expect(!PhotoSaveFailure(PHPhotosError(.invalidResource), addOnly: .authorized).accessOff)
    }
}
#endif
