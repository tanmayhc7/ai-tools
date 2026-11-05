import SwiftUI

/// Drop-in replacement for `@State`.
/// In recent SDKs `@State` is a macro whose compiler plugin ships only with full Xcode;
/// this wrapper builds on `@StateObject` so the app compiles with the Command Line Tools alone.
final class LocalBox<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

@propertyWrapper
struct Local<Value>: DynamicProperty {
    @StateObject private var box: LocalBox<Value>

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: LocalBox(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
