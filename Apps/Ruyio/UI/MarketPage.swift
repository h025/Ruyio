import AppKit
import RuyioCore
import RuyioHostKit
import RuyioPersistence
import SwiftUI

/// Plugin market (PRD §19.5–19.10). Source resolution lives in `MarketService`.
struct MarketPage: View {
    @ObservedObject var model: AppModel
    @State private var showAdd = false
    var l: L10n { model.l }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: l.market) { Button(l.addMarket) { showAdd = true }.buttonStyle(.borderedProminent) }
            MarketContent(model: model, showAdd: $showAdd)
        }
        .sheet(isPresented: $showAdd) { AddSourceSheet(model: model, isPresented: $showAdd) }
    }
}
