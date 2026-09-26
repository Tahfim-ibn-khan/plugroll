/// Carries a value that isn't marked Sendable across a task boundary, for types that are
/// in practice only used by one task at a time (Core Image filters, which the renderer
/// copies before use).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}
