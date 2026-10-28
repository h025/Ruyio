import Testing
import RuyioCore
import RuyioProtocol
import RuyioUI

@MainActor
struct SchemaContextTests {
    private let pluginID = PluginID("org.ruyio.test-ui")
    private let strings = SchemaStrings(submit: "Submit", cancel: "Cancel", undo: "Undo", loading: "Loading", choose: "Choose")

    private func context(root: UINode) -> SchemaContext {
        SchemaContext(pluginID: pluginID, document: ViewDocument(viewID: "items", revision: 1, root: root),
                      strings: strings, sendEvent: { _, _ in }, loadBlob: { _ in nil })
    }

    private func collection(items: [ListItem], footer: [ItemAction] = []) -> SchemaContext {
        context(root: .collection(CollectionSpec(searchPlaceholder: "Search", list: ListSpec(items: items, selection: items.first?.id),
                                                footerActions: footer)))
    }

    @Test func defaultAndDeclaredShortcutsUseThePluginActionIDs() {
        let actions = [ItemAction(id: "inspect-record", title: "Inspect", isDefault: true),
                       ItemAction(id: "export-record", title: "Export", shortcut: "command+shift+e")]
        let context = collection(items: [ListItem(id: "record-1", title: "A record", actions: actions)])
        #expect(context.invocation() == .invoke(actionID: "inspect-record", itemID: "record-1"))
        #expect(context.invocation(shortcut: KeyShortcut(key: "e", modifiers: [.command, .shift])) == .invoke(actionID: "export-record", itemID: "record-1"))
        #expect(context.invocation(shortcut: KeyShortcut(key: "v", modifiers: [.command])) == nil)
        #expect(context.invocation(shortcut: KeyShortcut(key: "delete", modifiers: [])) == nil)
    }

    @Test func nonCollectionViewsLeaveKeyboardHandlingToTheirControls() {
        let context = context(root: .form(FormSpec(fields: [FieldSpec(id: "name", label: "Name", kind: .textField)])))
        #expect(context.invocation() == nil)
        #expect(context.invocation(shortcut: KeyShortcut(key: "return", modifiers: [])) == nil)
        #expect(context.invocation(shortcut: KeyShortcut(key: "delete", modifiers: [])) == nil)
    }

    @Test func footerItemActionWithoutShortcutPreservesItsSelectedItem() {
        let remove = ItemAction(id: "remove-record", title: "Remove", isDestructive: true)
        let settings = ItemAction(id: "preferences", title: "Preferences")
        let context = collection(items: [ListItem(id: "record-1", title: "A record", actions: [remove])], footer: [remove, settings])
        #expect(context.footerInvocation(remove) == .invoke(actionID: "remove-record", itemID: "record-1"))
        #expect(context.footerInvocation(settings) == .invoke(actionID: "preferences", itemID: nil))
    }

    @Test func disabledItemsDoNotProduceDefaultOrShortcutInvocations() {
        let action = ItemAction(id: "open-record", title: "Open", shortcut: "command+o", isDefault: true)
        let context = collection(items: [ListItem(id: "disabled", title: "Unavailable", isDisabled: true, actions: [action])], footer: [action])
        #expect(context.invocation() == nil)
        #expect(context.invocation(shortcut: KeyShortcut(key: "o", modifiers: .command)) == nil)
        #expect(context.invocation(itemID: "disabled") == nil)
        #expect(context.footerInvocation(action) == nil)
    }

    @Test func footerDefaultResolvesTheClickedItemInsteadOfThePreviousSelection() {
        let itemAction = ItemAction(id: "inspect-record", title: "Inspect")
        let footerDefault = ItemAction(id: "inspect-record", title: "Inspect", isDefault: true)
        let context = collection(items: [ListItem(id: "old", title: "Previously selected", actions: [itemAction]),
                                         ListItem(id: "clicked", title: "Clicked row", actions: [itemAction])], footer: [footerDefault])
        #expect(context.localSelection == "old")
        #expect(context.invocation(itemID: "clicked") == .invoke(actionID: "inspect-record", itemID: "clicked"))
        #expect(context.invocation(itemID: "removed") == nil)
    }

    @Test func globalFooterActionsRemainAvailableWithoutASelection() {
        let remove = ItemAction(id: "remove-record", title: "Remove")
        let clear = ItemAction(id: "clear-unfavorited", title: "Clear unstarred", shortcut: "command+shift+k")
        let context = collection(items: [ListItem(id: "record", title: "A record", actions: [remove])], footer: [remove, clear])
        context.localSelection = nil
        #expect(context.footerInvocation(clear) == .invoke(actionID: "clear-unfavorited", itemID: nil))
        #expect(context.invocation(shortcut: KeyShortcut(key: "k", modifiers: [.command, .shift])) == .invoke(actionID: "clear-unfavorited", itemID: nil))
        #expect(context.footerInvocation(remove) == nil)
    }
}
