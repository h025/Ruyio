import AppKit
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import SwiftUI

/// Plugin market (PRD §19.5–19.10). Source resolution lives in `MarketService`.
struct MarketPage: View {
    @ObservedObject var model: AppModel
    @State private var showAdd = false
    @State private var tab = 0
    var l: L10n { model.l }

    var body: some View {
        MarketContent(model: model, showAdd: $showAdd, tab: $tab)
            .navigationTitle(l.market)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("", selection: $tab) {
                        Text(l.t("发现", "Discover")).tag(0)
                        Text(l.t("来源", "Sources")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label(l.addMarket, systemImage: "plus") }
                        .help(l.addMarket)
                }
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet(model: model, isPresented: $showAdd) }
    }
}
