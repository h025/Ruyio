import AppKit
import RuyioCore
import RuyioHostKit
import SwiftUI

struct MarketContent: View {
    @ObservedObject var model: AppModel
    @Binding var showAdd: Bool
    var l: L10n { model.l }

    var body: some View {
        VStack(spacing: 8) {
            Text(l.marketEmpty).font(.headline)
            Text(l.marketEmptyHint).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(l.addMarket) { showAdd = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

struct AddSourceSheet: View {
    @ObservedObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var address = ""
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l.addMarket.replacingOccurrences(of: "…", with: "")).font(.headline)
            Text(l.addressPrompt)
            TextField("https://", text: $address).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(l.cancel) { isPresented = false }.keyboardShortcut(.cancelAction)
                Button(l.resolve) {}.keyboardShortcut(.defaultAction).disabled(address.isEmpty)
            }
        }
        .padding(24).frame(width: 560)
    }
}
