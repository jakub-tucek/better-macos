import SwiftUI

// SDK 27 resolves @State to a macro whose plugin standalone CLT omits.
// Name the public property-wrapper type explicitly to retain pre-27 state semantics.
typealias StoredState<Value> = SwiftUI.State<Value>
