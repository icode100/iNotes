// A dependency-free runner for Apple's Command Line Tools, which omit XCTest.
// These are the same test methods used by the standard SwiftPM XCTest target.
#if INOTES_STANDALONE_TESTS
import Foundation

private enum TestFailure: Error { case unwrap }
private var failures = 0
private var activeTest = ""

class XCTestCase {
    func setUpWithError() throws {}
    func tearDownWithError() throws {}
}

func XCTFail(_ message: String = "Assertion failed", file: StaticString = #filePath, line: UInt = #line) {
    failures += 1
    fputs("FAIL \(activeTest): \(message) [\(file):\(line)]\n", stderr)
}

func XCTAssertTrue(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !condition() { XCTFail("Expected true", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertFalse(_ condition: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    do { if try condition() { XCTFail("Expected false", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() != rhs() { XCTFail("Values are unequal", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertEqual(_ lhs: @autoclosure () throws -> Double, _ rhs: @autoclosure () throws -> Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    do { if try abs(lhs() - rhs()) > accuracy { XCTFail("Values differ by more than \(accuracy)", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNotEqual<T: Equatable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try lhs() == rhs() { XCTFail("Values unexpectedly equal", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertLessThan<T: Comparable>(_ lhs: @autoclosure () throws -> T, _ rhs: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { if try !(lhs() < rhs()) { XCTFail("Expected less-than comparison", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() != nil { XCTFail("Expected nil", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTAssertNotNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    do { if try value() == nil { XCTFail("Expected non-nil", file: file, line: line) } }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}

func XCTUnwrap<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let unwrapped = try value() else {
        XCTFail("Expected value to unwrap", file: file, line: line)
        throw TestFailure.unwrap
    }
    return unwrapped
}

func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line, _ handler: (Error) -> Void = { _ in }) {
    do { _ = try expression(); XCTFail("Expected an error", file: file, line: line) }
    catch { handler(error) }
}

@main
struct StandaloneTestRunner {
    static func main() {
        let library = NoteLibraryTests()
        let repository = LibraryRepositoryTests()
        let themes = PageThemeTests()
        let pages = PageContentTests()
        let geometry = PageSelectionGeometryTests()
        let backups = BackupArchiveTests()
        let presentation = PagePresentationTests()
        let inkValidation = InkValidationTests()
        let tests: [(String, XCTestCase, () throws -> Void)] = [
            ("legacy line and template defaults", presentation, presentation.testLegacyArchivesDefaultToSolidLinesWithoutTemplates),
            ("line and template archive import duplicate", presentation, presentation.testLineAndTemplateChoicesSurviveSaveImportAndDuplicate),
            ("line pattern clipboard and selection", presentation, presentation.testPatternSurvivesClipboardAndSelectionTranslation),
            ("template compatibility and bounded dash lengths", presentation, presentation.testTemplateCompatibilityAndDashLengthsAreBounded),
            ("empty ink rejected before erase", inkValidation, inkValidation.testEmptyStrokeRejectedThroughArchiveAndClipboardBeforeEditing),
            ("extreme finite ink rejected", inkValidation, inkValidation.testExtremeFiniteCoordinatesRejectedAtEveryPortableBoundary),
            ("invalid ink values rejected", inkValidation, inkValidation.testInvalidWidthPressureAndNonfiniteGeometryAreRejected),
            ("ink stroke and sample budgets", inkValidation, inkValidation.testStrokeAndAggregatePointBudgets),
            ("empty pages and legitimate dots preserved", inkValidation, inkValidation.testEmptyPageOnePointDotsAndBoundaryCoordinatesStillRoundTrip),
            ("global vintage paper and contrast", themes, themes.testGlobalPaperPreferenceAndVintageContrast),
            ("mixed page archive and search", pages, pages.testMixedPageArchiveRoundTripAndSearch),
            ("legacy page object migration", pages, pages.testLegacyArchiveDefaultsAndPromotesBeforeAddingObjects),
            ("invalid page objects", pages, pages.testInvalidPageObjectsRejectWithoutChangingSavedNote),
            ("mixed page snapshots", pages, pages.testMixedSnapshotAndCopyPreserveAllContent),
            ("safe archive version", pages, pages.testVersionOneCannotSilentlyExportNewObjects),
            ("bounded mixed clipboard", pages, pages.testClipboardRejectsOversizedAndInvalidObjects),
            ("mixed page import", pages, pages.testImportedPagePreservesPositionedContentAndProtectsVersion),
            ("lasso crossing strokes", geometry, geometry.testCrossingStrokeSelectsEvenWhenBothEndpointsOutside),
            ("lasso thick ink and dots", geometry, geometry.testBoundaryAndThickInkAndDotsAreSelectable),
            ("lasso text geometry", geometry, geometry.testTextRectangleCanEncloseLassoAndLassoCanEncloseText),
            ("lasso concave and invalid input", geometry, geometry.testConcaveAndInvalidPolygons),
            ("selection ink preservation", geometry, geometry.testTranslationPreservesIdentityStylePressureAndCanonicalColor),
            ("independent cloud folder backups", backups, backups.testTwoDestinationsKeepIndependentCompleteArchives),
            ("versioned backups", backups, backups.testVersionedWritesNeverReplaceAnExistingBackup),
            ("failed cloud folder backup", backups, backups.testUnavailableDestinationAndInvalidArchivePreserveLocalData),
            ("independent backup scheduling", backups, backups.testScheduleThrottlesTargetsAndRetriesIndependently),
            ("theme text and ink contrast", themes, themes.testDefaultTextAndDarkInkContrast),
            ("theme palette storage roundtrip", themes, themes.testKnownPaletteRoundTripsBetweenDisplayAndStorage),
            ("theme custom hue resolution", themes, themes.testCustomDarkHuesLightenButBrightColorsStayUnchanged),
            ("theme input normalization", themes, themes.testHexNormalizationAndInvalidInputHaveReadableFallbacks),
            ("theme archive color preservation", themes, themes.testThemeResolutionNeverRewritesArchivedStrokes),
            ("hierarchy and order", library, library.testHierarchyAndOrderedChildren),
            ("invalid parents and titles", library, library.testInvalidParentsAndTitlesLeaveLibraryUnchanged),
            ("move cycles and reorder", library, library.testMoveRejectsCycleAndAllowsReordering),
            ("search and favorites", library, library.testSearchUsesAllTokensTitlesBodiesTagsAndAccentFolding),
            ("trash and restore", library, library.testTrashSubtreeAndRestoreAncestors),
            ("permanent subtree deletion", library, library.testPermanentDeleteRequiresTrashAndDeletesSubtree),
            ("duplicate with attachments", library, library.testDuplicateRemapsTreeAndKeepsContent),
            ("merge remaps identifiers", library, library.testMergeRemapsEveryIDAndDoesNotOverwrite),
            ("Unicode and media roundtrip", library, library.testArchiveRoundTripAllMediaAndUnicode),
            ("malformed and future archives", library, library.testMalformedAndFutureArchivesRejected),
            ("invalid updates and ink", library, library.testContentUpdateCannotCreateCycleOrInvalidDrawing),
            ("attachment traversal", library, library.testAttachmentTraversalNameRejected),
            ("empty trash", library, library.testEmptyTrashRetainsActiveNotes),
            ("sample library", library, library.testSampleLibraryValidAndHasSheet),
            ("depth limit", library, library.testDepthLimitCannotBeBypassedByParentFirstOrder),
            ("1000 sheet scale", library, library.testThousandSheetLibraryRemainsCompactAndSearchable),
            ("oversized import and duplicate atomicity", library, library.testOversizedMergeAndDuplicateDoNotCommitPartialChanges),
            ("untrusted order overflow", library, library.testUntrustedOrderingCannotOverflow),
            ("trash search and byte budget", library, library.testTrashSearchIsExplicitAndNodeByteBudgetMatchesArchive),
            ("payload optimization invariants", library, library.testPayloadOptimizationCannotBypassStructuralAndDateChecks),
            ("ink and paper styles persist", library, library.testEveryInkAndPaperStylePersists),
            ("legacy v1 ink and paper defaults", library, library.testLegacyVersionOneDefaultsToPenAndDottedPaper),
            ("save reopen and previous backup", repository, repository.testNewRepositorySaveReopenAndBackupKeepsPreviousVersion),
            ("external edit conflict", repository, repository.testExternalModificationRefusesOverwriteAndPreservesBothVersions),
            ("external deletion conflict", repository, repository.testExternalDeletionAndUnexpectedExistingFileRefuseOverwrite),
            ("corrupt library explicit recovery", repository, repository.testCorruptLibraryIsPreservedAndSavesAreBlockedUntilExplicitRecovery),
            ("missing recovery backup", repository, repository.testRecoveryWithoutBackupDoesNotModifyPrimary),
            ("oversized file bounded reader", repository, repository.testBoundedReaderRejectsOversizedSparseFileBeforeLoading),
            ("export import persistence integration", repository, repository.testArchiveImportAndExportIntegration)
        ]
        let started = Date()
        for (name, instance, test) in tests {
            activeTest = name
            let before = failures
            do {
                try instance.setUpWithError()
                try test()
            } catch { XCTFail("Uncaught error: \(error)") }
            do { try instance.tearDownWithError() } catch { XCTFail("Teardown: \(error)") }
            if failures == before { print("PASS \(name)") }
        }
        print("\(tests.count) tests, \(failures) failures, \(String(format: "%.2f", Date().timeIntervalSince(started))) seconds")
        if failures > 0 { exit(1) }
    }
}
#endif
