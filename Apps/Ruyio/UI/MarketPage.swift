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
    @State private var refreshRequest = 0
    @State private var refreshing = false
    var l: L10n { model.l }

    init(model: AppModel) {
        self.model = model
        #if DEBUG
        _tab = State(initialValue: model.isGallery ? model.galleryMarketTab : 0)
        #else
        _tab = State(initialValue: 0)
        #endif
    }

    var body: some View {
        MarketContent(model: model, showAdd: $showAdd, tab: $tab, refreshRequest: refreshRequest, refreshing: $refreshing)
            .navigationTitle(l.market)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker(l.t("市场视图", "Market View"), selection: $tab) {
                        Text(l.t("发现", "Discover")).tag(0)
                        Text(l.t("来源", "Sources")).tag(1)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { refreshRequest += 1 } label: {
                        if refreshing { ProgressView().controlSize(.small) } else { Label(l.t("刷新市场", "Refresh Markets"), systemImage: "arrow.clockwise") }
                    }
                        .help(l.t("刷新所有已启用的市场", "Refresh all enabled markets"))
                        .disabled(refreshing)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label(l.addMarket, systemImage: "plus") }
                        .help(l.addMarket)
                }
            }
            .sheet(isPresented: $showAdd) { AddSourceSheet(model: model, isPresented: $showAdd) }
    }
}
