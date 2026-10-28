import Testing
@testable import RuyioUI
import RuyioProtocol
import RuyioCore

struct FormDraftTests {
    private func fields(_ value: String) -> [FieldSpec] {
        [FieldSpec(id: "apps", label: "Applications", kind: .textEditor, value: .string(value))]
    }

    @Test func backgroundUpdatesPreserveDirtyValuesAndRefreshCleanFields() {
        var draft = FormDraft()
        draft.update(fields: fields("original"))
        draft.set(.string("draft"), for: "apps")
        draft.update(fields: fields("remote"))
        #expect(draft.values["apps"] == .string("draft"))
        draft.set(.string("remote"), for: "apps")
        draft.update(fields: fields("latest"))
        #expect(draft.values["apps"] == .string("latest"))
    }

    @Test func successfulSaveAcceptsNormalizationAndBecomesClean() {
        var draft = FormDraft()
        draft.update(fields: fields(""))
        draft.set(.string("  com.example.app  \n"), for: "apps")
        let submitted = draft.prepareSubmission(fields: fields(""))
        draft.update(fields: fields("com.example.app"), acknowledgement: .init(submitted: submitted, normalized: ["apps": .string("com.example.app")]))
        #expect(draft.values["apps"] == .string("com.example.app"))
        draft.update(fields: fields("com.example.other"))
        #expect(draft.values["apps"] == .string("com.example.other"))
    }

    @Test func acknowledgementPreservesEditsMadeAfterSubmissionIncludingReverts() {
        for edited in ["new draft", "original"] {
            var draft = FormDraft()
            draft.update(fields: fields("original"))
            draft.set(.string("  submitted  "), for: "apps")
            let submitted = draft.prepareSubmission(fields: fields("original"))
            draft.set(.string(edited), for: "apps")
            // Also cover delivery of the response document before its acknowledgement.
            draft.update(fields: fields("submitted"))
            draft.update(fields: fields("submitted"), acknowledgement: .init(submitted: submitted, normalized: ["apps": .string("submitted")]))
            #expect(draft.values["apps"] == .string(edited))
        }
    }

    @Test func failedSaveHasNoAcknowledgementAndNextSaveUsesCurrentDraft() {
        var draft = FormDraft()
        draft.update(fields: fields("original"))
        draft.set(.string("first"), for: "apps")
        _ = draft.prepareSubmission(fields: fields("original"))
        draft.update(fields: fields("original"))
        #expect(draft.values["apps"] == .string("first"))
        draft.set(.string("second"), for: "apps")
        #expect(draft.prepareSubmission(fields: fields("original"))["apps"] == .string("second"))
    }

    @Test func acknowledgementWithoutDocumentDoesNotRestoreOldSchemaValues() {
        var draft = FormDraft()
        draft.update(fields: fields("original"))
        draft.set(.string("submitted"), for: "apps")
        let submitted = draft.prepareSubmission(fields: fields("original"))
        draft.update(fields: fields("original"), acknowledgement: .init(submitted: submitted, normalized: nil))
        #expect(draft.values["apps"] == .string("submitted"))
    }

    @Test func removedFieldsDoNotReturnWithAnAcknowledgement() {
        var draft = FormDraft()
        draft.update(fields: fields("original"))
        let submitted = draft.prepareSubmission(fields: fields("original"))
        draft.update(fields: [], acknowledgement: .init(submitted: submitted, normalized: submitted))
        #expect(draft.values.isEmpty)
    }

    @MainActor @Test func contextIgnoresAcknowledgementsForStaleOrForeignDocuments() {
        let original = ViewDocument(viewID: "settings", revision: 3, root: .form(FormSpec(fields: fields("original"))))
        let context = SchemaContext(pluginID: PluginID("org.example.plugin"), document: original,
            strings: SchemaStrings(submit: "Save", cancel: "Cancel", undo: "", loading: "", choose: ""),
            sendEvent: { _, _ in }, loadBlob: { _ in nil })
        context.acknowledgeSubmission(["apps": .string("saved")], document: ViewDocument(viewID: "settings", revision: 2, root: original.root))
        #expect(context.formSubmissionAcknowledgement == nil)
        context.acknowledgeSubmission(["apps": .string("saved")], document: ViewDocument(viewID: "other", revision: 4, root: original.root))
        #expect(context.formSubmissionAcknowledgement == nil)
        context.acknowledgeSubmission(["apps": .string("saved")], document: nil)
        #expect(context.formSubmissionAcknowledgement?.submitted["apps"] == .string("saved"))
    }
}
