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
        let retention = BackupRetentionTests()
        let legacyCleanup = LegacyBackupCleanupTests()
        let presentation = PagePresentationTests()
        let inkValidation = InkValidationTests()
        let images = PageImageTests()
        let diagrams = PageDiagramTests()
        let tests: [(String, XCTestCase, () throws -> Void)] = [
            ("diagram archive persistence import search snapshots", diagrams, diagrams.testDiagramArchivePersistenceDuplicateImportSearchAndSnapshots),
            ("legacy diagram defaults and format promotion", diagrams, diagrams.testLegacyDiagramDefaultsAndStickyFormatFourPromotion),
            ("diagram geometry style attachment atomic rejection", diagrams, diagrams.testInvalidDiagramGeometryStyleAndAttachmentRejectAtomically),
            ("diagram table text and pattern budgets", diagrams, diagrams.testTableAndDiagramTextObjectAndPatternBudgets),
            ("connector anchors routing hit testing", diagrams, diagrams.testConnectorAnchorsRoutingHitTestingAndBoundaryDetachment),
            ("diagram move delete clipboard graph", diagrams, diagrams.testDiagramMoveDeleteAndCopyRemapPreserveConnectorGraph),
            ("mixed diagram clipboard validation", diagrams, diagrams.testDiagramMixedClipboardRoundTripAndValidation),
            ("annotated image save duplicate import", images, images.testImageArchiveSaveDuplicateAndImportPreserveAnnotatedPage),
            ("legacy image defaults and version promotion", images, images.testLegacyArchivesSnapshotsAndClipboardDefaultImagesAndPromoteOnlyWhenNeeded),
            ("image geometry atomic rejection", images, images.testImageGeometryAndIDsRejectAtomicallyAcrossArchiveAndClipboard),
            ("image byte pixel and container bounds", images, images.testImageBytePixelAndContainerLimitsRejectBeforeRendering),
            ("image archive version and mixed clipboard", images, images.testImagesRequireVersionThreeAndMixedClipboardRetainsBytes),
            ("image archive size atomicity", images, images.testImageAggregateArchiveLimitRejectsDuplicateAndImportAtomically),
            ("legacy line and template defaults", presentation, presentation.testLegacyArchivesDefaultToSolidLinesWithoutTemplates),
            ("line and template archive import duplicate", presentation, presentation.testLineAndTemplateChoicesSurviveSaveImportAndDuplicate),
            ("line pattern clipboard and selection", presentation, presentation.testPatternSurvivesClipboardAndSelectionTranslation),
            ("template compatibility and bounded dash lengths", presentation, presentation.testTemplateCompatibilityAndDashLengthsAreBounded),
            ("empty ink rejected before erase", inkValidation, inkValidation.testEmptyStrokeRejectedThroughArchiveAndClipboardBeforeEditing),
            ("extreme finite ink rejected", inkValidation, inkValidation.testExtremeFiniteCoordinatesRejectedAtEveryPortableBoundary),
            ("invalid ink values rejected", inkValidation, inkValidation.testInvalidWidthPressureAndNonfiniteGeometryAreRejected),
            ("ink stroke and sample budgets", inkValidation, inkValidation.testStrokeAndAggregatePointBudgets),
            ("empty pages and legitimate dots preserved", inkValidation, inkValidation.testEmptyPageOnePointDotsAndBoundaryCoordinatesStillRoundTrip),
            ("pattern amplification rejected at boundaries", inkValidation, inkValidation.testPatternAmplificationRejectedByArchiveClipboardAndAtomicUpdate),
            ("pattern cubic and aggregate work limits", inkValidation, inkValidation.testPatternBudgetCountsCurveOvershootAndTheWholePage),
            ("ordinary patterned tables preserved", inkValidation, inkValidation.testOrdinaryPatternedTablesRemainAccepted),
            ("global vintage paper and contrast", themes, themes.testGlobalPaperPreferenceAndVintageContrast),
            ("scenery paper and legacy forest", themes, themes.testMatchingPaperFollowsSceneryAndLegacyForestPreference),
            ("fixed papers and neutral pitch guides", themes, themes.testExplicitPaperChoicesStayFixedAndPitchGuidesAreNeutral),
            ("all paper contrast", themes, themes.testEveryPaperHasReadableTextGuidesAndTemplate),
            ("all dark paper canonical and custom ink", themes, themes.testAllDarkPapersAdaptPaletteAndCustomInkWithoutLosingCanonicalColors),
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
            ("backup recent daily weekly retention", retention, retention.testRetentionPlannerKeepsRecentDailyAndWeeklyRecoveryPoints),
            ("backup UTC retention boundaries", retention, retention.testRetentionPlannerUsesUTCDayAndISOWeekBoundaries),
            ("backup byte budget and recovery floor", retention, retention.testRetentionBudgetTrimsOlderPointsButPreservesTwoNewest),
            ("backup deterministic and malformed metadata", retention, retention.testRetentionPlannerIsStableForDateTiesAndRejectsMalformedMetadata),
            ("bounded complete backup history", retention, retention.testFrequentManagedBackupsRetainFiveCompleteRecentCopies),
            ("duplicate backup suppression", retention, retention.testIdenticalManagedBackupIsSkippedAcrossSeparateCalls),
            ("backup ownership and export isolation", retention, retention.testRetentionPreservesOtherOwnersLegacyExportsAndUnrecognizedFiles),
            ("multibyte backup filename isolation", retention, retention.testMultibyteLookalikeFilenameIsPreservedWithoutInterruptingBackups),
            ("failed backup history preservation", retention, retention.testFailedManagedWritePreservesAllExistingRecoveryCopies),
            ("managed backup name collision", retention, retention.testManagedNameCollisionNeverReplacesSavedContents),
            ("rapid and backward-clock backup retention", retention, retention.testRapidAndBackwardClockWritesProtectTheActualLatestCopies),
            ("independent retention destinations", retention, retention.testDestinationsRetainAndDeduplicateIndependently),
            ("backup readback verification before pruning", retention, retention.testUnverifiedNewBackupCannotPruneExistingHistory),
            ("backup directory replacement during write", retention, retention.testOwnerDirectoryReplacementDuringWritePreservesOriginalHistory),
            ("backup cleanup failure and retry", retention, retention.testCleanupFailureDoesNotMisreportVerifiedBackupAsFailed),
            ("corrupt backup recovery protection", retention, retention.testCorruptNewestCopyDoesNotReplaceValidRecoveryProtection),
            ("corrupt historical backup recovery protection", retention, retention.testCorruptHistoricalRepresentativeCannotDisplaceValidDailyOrWeeklyRecovery),
            ("historical backup replacement stops cleanup", retention, retention.testHistoricalRecoveryReplacementStopsCleanupBeforeRemovingOtherCopies),
            ("backup replacement during cleanup", retention, retention.testCleanupPreservesAFileReplacedAfterRetentionPlanning),
            ("backup symlink isolation", retention, retention.testManagedBackupRejectsSymlinkDirectoriesAndPreservesLinkedFiles),
            ("legacy backup review preserves unknown files", legacyCleanup, legacyCleanup.testLegacyPreviewProtectsNewestAndIgnoresUnrecognizedFiles),
            ("explicit legacy backup cleanup", legacyCleanup, legacyCleanup.testExplicitLegacyCleanupPreservesNewestManualExportsAndManagedHistory),
            ("changed legacy backup cleanup rejection", legacyCleanup, legacyCleanup.testChangedLegacySelectionRejectsBeforeDeletingAnyFile),
            ("legacy cleanup recovery and selection guards", legacyCleanup, legacyCleanup.testLegacyCleanupRequiresVerifiedCurrentBackupAndRejectsProtectedOrForgedIDs),
            ("legacy cleanup folder replacement rejection", legacyCleanup, legacyCleanup.testLegacyCleanupRejectsFolderReplacementAndSymlinkedBackupFolder),
            ("bounded legacy cleanup batch progress", legacyCleanup, legacyCleanup.testBoundedLegacyReviewBatchesMakeProgressWithoutDroppingNewestProtection),
            ("legacy protected-copy replacement stops cleanup", legacyCleanup, legacyCleanup.testProtectedLegacyReplacementStopsCleanupAndReportsActualPartialCount),
            ("theme text and ink contrast", themes, themes.testDefaultTextAndDarkInkContrast),
            ("theme palette storage roundtrip", themes, themes.testKnownPaletteRoundTripsBetweenDisplayAndStorage),
            ("theme custom hue resolution", themes, themes.testCustomDarkHuesLightenButBrightColorsStayUnchanged),
            ("theme input normalization", themes, themes.testHexNormalizationAndInvalidInputHaveReadableFallbacks),
            ("theme archive color preservation", themes, themes.testThemeResolutionNeverRewritesArchivedStrokes),
            ("hierarchy and order", library, library.testHierarchyAndOrderedChildren),
            ("subtree membership compatibility", library, library.testSubtreeMembershipPreservesMovesTrashAndArrayOrder),
            ("near-limit leaf-first subtree", library, library.testNearLimitLeafFirstHierarchyHasBoundedSubtreeQuery),
            ("invalid parents and titles", library, library.testInvalidParentsAndTitlesLeaveLibraryUnchanged),
            ("untitled sheets and required folder names", library, library.testUntitledSheetsPersistWithoutWeakeningFolderNames),
            ("page-order numbering and removed tail", library, library.testSheetNumbersFollowPageOrderAndReuseRemovedTail),
            ("middle deletion and drag page renumbering", library, library.testMiddleDeletionCompactsPagesAndDraggingNewSheetRenumbersInPageOrder),
            ("empty folder restarts sheet numbers", library, library.testRemovingAllSheetsRestartsAtOneWithOrWithoutRetainedTrash),
            ("number reuse preserves annotated Trash pages", library, library.testNumberReusePreservesTrashedAnnotatedPageAndArchiveCompatibility),
            ("number reuse rejected mutation atomicity", library, library.testNumberReuseRejectsInvalidMovesAndUpdatesAtomically),
            ("sheet numbering move duplicate import", library, library.testSheetMoveDuplicateAndImportKeepIndependentSequences),
            ("page numbering structural updates and moves", library, library.testStructuralUpdatesAndMovesReindexSourceAndDestinationPages),
            ("page order after ancestor and folder restore", library, library.testRestoringSheetAncestorsAndFoldersReinstatesPageOrder),
            ("trashed cross-parent move archive collision", library, library.testMovingTrashedSheetsAcrossParentsKeepsUniqueArchiveNumbersAndContent),
            ("folder duplicate and archive page gaps", library, library.testFolderDuplicateAndOldArchiveImportNormalizePageGaps),
            ("large folder restore page numbering", library, library.testLargeFolderRestoreReindexesInOneBoundedPass),
            ("page numbering deterministic order ties", library, library.testPageNumberOrderTiesUseCreationDateThenUUIDWithoutChangingStoredOrder),
            ("legacy page-order numbering migration", library, library.testLegacyNumberMigrationUsesPageOrderAndPreservesAllContent),
            ("sheet numbering tampering atomicity", library, library.testNumberTamperingCannotPartiallyMutateLibrary),
            ("historical maximum sheet counters", library, library.testHistoricalMaximumCounterDoesNotBlockAvailableSheetNumbers),
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
            ("attachment empty and exact limit", repository, repository.testAttachmentBoundedReaderAcceptsEmptyAndExactLimitFiles),
            ("attachment upfront oversize", repository, repository.testAttachmentBoundedReaderRejectsDenseAndSparseOversizeBeforeReading),
            ("attachment append growth", repository, repository.testAttachmentBoundedReaderStopsAtLimitPlusOneAfterAppend),
            ("attachment sparse growth", repository, repository.testAttachmentBoundedReaderStopsAtLimitPlusOneAfterSparseGrowth),
            ("bounded short reads", repository, repository.testBoundedReaderContinuesAfterShortReadsAndDetectsGrowth),
            ("bounded pathname replacement", repository, repository.testBoundedReaderKeepsOpenedFileWhenPathIsReplaced),
            ("regular files and symlinks", repository, repository.testBoundedReaderRejectsNonregularFilesAndAcceptsRegularSymlinks),
            ("large archived attachment compatibility", repository, repository.testArchiveReadPreservesAttachmentsLargerThanPickerLimit),
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
