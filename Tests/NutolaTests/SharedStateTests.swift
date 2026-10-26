import Testing

// These suites change UserDefaults.standard or retry process-wide pending writes.
// A common parent prevents interference even when the rest of the tests run in parallel.
@Suite(.serialized)
struct SharedStateTests {}
