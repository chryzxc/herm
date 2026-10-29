import SwiftUI

struct MessagePinMutationFeedback: Equatable {
    let id = UUID()
    let error: String?
}

struct MessagePinFeedbackPresentation: ViewModifier {
    @ObservedObject var model: DockModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: model.messagePinError) { _, error in
                if error != nil && model.messagePinsSupported { isPresented = true }
            }
            .onChange(of: model.messagePinMutationFeedback?.id) { _, id in
                if id != nil { isPresented = true }
            }
    }
}
