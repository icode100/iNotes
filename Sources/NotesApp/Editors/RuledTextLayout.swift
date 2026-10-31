import Foundation
import ObjectiveC
#if os(macOS)
import AppKit
typealias RuledNativeTextView = NSTextView
typealias RuledNativeFont = NSFont
#else
import UIKit
typealias RuledNativeTextView = UITextView
typealias RuledNativeFont = UIFont
#endif

/// A display-only baseline grid. Canonical RTF paragraph attributes stay intact.
@MainActor
final class RuledTextLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
    static let spacing: CGFloat = 28
    private static var associationKey: UInt8 = 0
    private weak var view: RuledNativeTextView?
    private weak var manager: NSLayoutManager?
    private weak var previousDelegate: NSLayoutManagerDelegate?
    private var pageOriginY: CGFloat = 0
    private var metricFont: RuledNativeFont?
    private var metricParagraph: NSParagraphStyle?
    private var metricBaseline: CGFloat = 0
    private var metricHeight: CGFloat = 0

    static func attach(to view: RuledNativeTextView, paper: InkPaper, pageOriginY: CGFloat) {
        #if os(macOS)
        guard let manager = view.layoutManager else { return }
        (view as? NotesTextView)?.usesRuledPaper = paper == .ruled
        #else
        let manager = view.layoutManager
        #endif
        let existing = objc_getAssociatedObject(view, &associationKey) as? RuledTextLayout
        guard paper == .ruled else {
            if let existing {
                if (manager.delegate as AnyObject?) === existing { manager.delegate = existing.previousDelegate }
                objc_setAssociatedObject(view, &associationKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                invalidate(manager)
            }
            return
        }
        let origin = pageOriginY.isFinite ? pageOriginY : 0
        if let existing, existing.manager === manager {
            guard existing.pageOriginY != origin else { existing.updateEmptyLayout(); return }
            existing.pageOriginY = origin
            invalidate(manager)
            existing.updateEmptyLayout()
            return
        }
        let helper = RuledTextLayout()
        helper.view = view
        helper.manager = manager
        helper.previousDelegate = manager.delegate
        helper.pageOriginY = origin
        manager.delegate = helper
        objc_setAssociatedObject(view, &associationKey, helper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        invalidate(manager)
        helper.updateEmptyLayout()
    }

    /// Typing attributes can change on an empty paragraph without invalidating glyphs.
    static func refresh(_ view: RuledNativeTextView) {
        guard let helper = objc_getAssociatedObject(view, &associationKey) as? RuledTextLayout,
              let manager = helper.manager else { return }
        invalidate(manager)
        helper.updateEmptyLayout()
    }

    private static func invalidate(_ manager: NSLayoutManager) {
        let range = NSRange(location: 0, length: manager.textStorage?.length ?? 0)
        manager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        manager.invalidateDisplay(forCharacterRange: range)
    }

    private var containerTop: CGFloat {
        #if os(macOS)
        return view?.textContainerOrigin.y ?? 0
        #else
        return view?.textContainerInset.top ?? 0
        #endif
    }

    private func phaseShift(fragmentY: CGFloat, baseline: CGFloat, first: Bool = false) -> CGFloat {
        let absolute = pageOriginY + containerTop + fragmentY + baseline
        let row = (absolute + 1 - 0.000_01) / Self.spacing
        // Initial padding must stay inside the container. Subsequent runs can
        // have taller fallback glyphs (Hindi/emoji) within the same 16pt body;
        // nearest-row snapping keeps those wrapped lines one rule apart.
        return (first ? ceil(row) : row.rounded()) * Self.spacing - 1 - absolute
    }

    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldSetLineFragmentRect fragment: UnsafeMutablePointer<CGRect>,
                       lineFragmentUsedRect used: UnsafeMutablePointer<CGRect>,
                       baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        _ = previousDelegate?.layoutManager?(layoutManager, shouldSetLineFragmentRect: fragment,
                                             lineFragmentUsedRect: used, baselineOffset: baselineOffset,
                                             in: textContainer, forGlyphRange: glyphRange)
        guard fragment.pointee.minY.isFinite, fragment.pointee.height.isFinite,
              baselineOffset.pointee.isFinite else { return false }
        let shift = phaseShift(fragmentY: fragment.pointee.minY, baseline: baselineOffset.pointee,
                               first: glyphRange.location == 0)
        // Moving the fragment, rather than adding to its baseline offset, makes
        // a 16pt body advance one ruled row even when the first line needs padding.
        fragment.pointee.origin.y += shift
        fragment.pointee.size.height = max(Self.spacing, ceil(fragment.pointee.height / Self.spacing) * Self.spacing)
        used.pointee.origin.y += shift
        return true
    }

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        if let textContainer { updateExtraFragment(layoutManager, container: textContainer) }
        previousDelegate?.layoutManager?(layoutManager, didCompleteLayoutFor: textContainer, atEnd: layoutFinishedFlag)
    }

    private func updateEmptyLayout() {
        guard let manager, (manager.textStorage?.length ?? 0) == 0, let container = view?.textContainer else { return }
        #if os(macOS)
        _ = view?.textContainerOrigin
        #else
        view?.layoutIfNeeded()
        if let view { _ = view.caretRect(for: view.beginningOfDocument) }
        #endif
        manager.ensureLayout(for: container)
        if manager.extraLineFragmentRect.height <= 0, let view {
            // Resizable empty AppKit views may defer this fragment until focus.
            // Complete it from a separately measured native typing-font line;
            // no placeholder character or paragraph attribute enters the note.
            _ = emptyBaseline(in: view)
            let height = max(1, metricHeight)
            let rect = CGRect(x: 0, y: 0, width: max(1, container.size.width), height: height)
            let used = CGRect(x: container.lineFragmentPadding, y: 0,
                              width: max(1, container.lineFragmentPadding * 2), height: height)
            manager.setExtraLineFragmentRect(rect, usedRect: used, textContainer: container)
        }
        updateExtraFragment(manager, container: container)
    }

    private func updateExtraFragment(_ layoutManager: NSLayoutManager, container textContainer: NSTextContainer) {
        if layoutManager.extraLineFragmentTextContainer === textContainer,
           layoutManager.extraLineFragmentRect.height > 0, let view {
            let baseline = emptyBaseline(in: view)
            var rect = layoutManager.extraLineFragmentRect
            var used = layoutManager.extraLineFragmentUsedRect
            let shift = phaseShift(fragmentY: rect.minY, baseline: baseline,
                                   first: (layoutManager.textStorage?.length ?? 0) == 0)
            rect.origin.y += shift
            rect.size.height = max(Self.spacing, ceil(rect.height / Self.spacing) * Self.spacing)
            used.origin.y += shift
            if rect != layoutManager.extraLineFragmentRect || used != layoutManager.extraLineFragmentUsedRect {
                layoutManager.setExtraLineFragmentRect(rect, usedRect: used, textContainer: textContainer)
            }
        }
    }

    private func emptyBaseline(in view: RuledNativeTextView) -> CGFloat {
        let font = view.typingAttributes[.font] as? RuledNativeFont ?? view.font ?? .systemFont(ofSize: 16)
        let paragraph = view.typingAttributes[.paragraphStyle] as? NSParagraphStyle ?? .default
        if metricFont?.isEqual(font) == true, metricParagraph?.isEqual(paragraph) == true { return metricBaseline }
        // Measure a separate native space; never insert a placeholder in the note.
        let storage = NSTextStorage(string: " ", attributes: [.font: font, .paragraphStyle: paragraph])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1_000, height: 1_000))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        metricFont = font
        metricParagraph = paragraph.copy() as? NSParagraphStyle
        metricBaseline = layout.numberOfGlyphs > 0 ? layout.location(forGlyphAt: 0).y : font.ascender
        metricHeight = layout.numberOfGlyphs > 0 ? layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height : font.ascender - font.descender
        return metricBaseline
    }
}
