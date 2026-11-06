import Testing

@testable import Solobill

@Suite struct PushRouteTests {
    @Test func aRenewalOpensTheRenewalsTab() {
        #expect(PushRoute(kind: "renewal_draft", link: "/invoices/5") == .renewals)
    }

    @Test func otherRemindersOpenTheirDocument() {
        #expect(PushRoute(kind: "invoice_overdue", link: "/invoices/5") == .invoice(5))
        #expect(PushRoute(kind: "original_due", link: "/originals/3") == .original(3))
    }

    @Test func anUnknownLinkOpensNothing() {
        #expect(PushRoute(kind: "invoice_overdue", link: nil) == nil)
        #expect(PushRoute(kind: "invoice_overdue", link: "/customers/1") == nil)
        #expect(PushRoute(kind: "invoice_overdue", link: "/invoices/abc") == nil)
        #expect(PushRoute(kind: nil, link: "/invoices/0") == nil)
    }
}
