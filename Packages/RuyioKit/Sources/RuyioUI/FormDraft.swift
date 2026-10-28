import Foundation
import RuyioProtocol

/// A successful submit may contain normalized values; its ID distinguishes repeated identical saves.
public struct FormSubmissionAcknowledgement: Equatable, Sendable {
    public let id: UUID
    public let submitted: [String: JSONValue]
    public let normalized: [String: JSONValue]?

    public init(submitted: [String: JSONValue], normalized: [String: JSONValue]?) {
        id = UUID()
        self.submitted = submitted
        self.normalized = normalized
    }
}

/// Keeps local edits separate from the last server values and the last submitted snapshot.
struct FormDraft: Equatable, Sendable {
    private(set) var values: [String: JSONValue] = [:]
    private var baseline: [String: JSONValue] = [:]
    private var submitted: [String: JSONValue]?
    private var acknowledgementID: UUID?

    mutating func set(_ value: JSONValue, for id: String) { values[id] = value }

    mutating func prepareSubmission(fields: [FieldSpec]) -> [String: JSONValue] {
        let result = Dictionary(fields.map { ($0.id, values[$0.id] ?? $0.value) }, uniquingKeysWith: { _, last in last })
        submitted = result
        return result
    }

    mutating func update(fields: [FieldSpec], acknowledgement: FormSubmissionAcknowledgement? = nil) {
        let next = Dictionary(fields.map { ($0.id, $0.value) }, uniquingKeysWith: { _, last in last })
        values = values.filter { next[$0.key] != nil }
        for (id, value) in next {
            let changedAfterSubmission = submitted.flatMap { $0[id] }.map { values[id] != $0 } ?? false
            if values[id] == nil || (values[id] == baseline[id] && !changedAfterSubmission) {
                values[id] = value
            }
        }
        baseline = next
        guard let acknowledgement, acknowledgement.id != acknowledgementID else { return }
        acknowledgementID = acknowledgement.id
        let saved = acknowledgement.normalized ?? acknowledgement.submitted
        for (id, submittedValue) in acknowledgement.submitted where next[id] != nil {
            guard let savedValue = saved[id] else { continue }
            // Edits made after Save remain drafts, even when they revert to the former server value.
            if values[id] == submittedValue { values[id] = savedValue }
            baseline[id] = savedValue
        }
        submitted = nil
    }
}
