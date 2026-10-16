import SwiftUI

struct EditorOffer: Identifiable {
    var id: UUID
    var session: UUID?
    var text: String
}

struct EditorOfferPrompt: ViewModifier {
    @Binding var offer: EditorOffer?
    let replace: (EditorOffer) -> Void
    func body(content: Content) -> some View {
        content.confirmationDialog("Replace your draft with Pi's text?", isPresented: Binding(
            get: { offer != nil }, set: { if !$0 { offer = nil } }
        ), presenting: offer) { value in
            Button("Replace draft", role: .destructive) { replace(value) }
            Button("Keep my draft", role: .cancel) { offer = nil }
        } message: { _ in Text("Pi sent editor text. Your current draft will change only if you choose Replace draft. Nothing will be sent automatically.") }
    }
}
