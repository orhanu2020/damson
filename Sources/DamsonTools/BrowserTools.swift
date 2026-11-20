import Foundation
import DamsonSupport
import AppKit
import WebKit
import DamsonProviders

/// A dedicated, sandboxed browser profile for helper agents. It uses its own persistent
/// data store (no access to your everyday browser's logins, cookies or history).
/// If a task needs a signed-in site, open this window and sign in there yourself.
@MainActor
public final class SandboxBrowser: NSObject, WKNavigationDelegate {
    public static let shared = SandboxBrowser()

    // Fixed identifier = one persistent, separate profile for Damson.
    private static let profileID = UUID(uuidString: "6D3B8C0E-5E7A-4C55-9A57-7A1B1B3D0DA5")!

    public let webView: WKWebView
    private let window: NSWindow
    private var pendingNavigation: CheckedContinuation<Void, Never>?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: SandboxBrowser.profileID)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Damson Sandbox Browser"
        window.contentView = webView
        window.isReleasedWhenClosed = false
        webView.navigationDelegate = self
    }

    public func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func clearData() async {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: Date(timeIntervalSince1970: 0))
    }

    private func finishNavigation() {
        if let c = pendingNavigation {
            pendingNavigation = nil
            c.resume()
        }
    }

    public func navigate(to url: URL) async {
        // Finish any earlier wait so a continuation is never leaked.
        finishNavigation()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            self.pendingNavigation = c
            self.webView.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                self.finishNavigation()
            }
        }
    }

    public func evaluate(_ script: String) async throws -> String {
        let result = try await webView.evaluateJavaScript(script)
        if let s = result as? String { return s }
        if let n = result as? NSNumber { return n.stringValue }
        if result == nil { return "" }
        return String(describing: result!)
    }

    public func currentURL() -> String { webView.url?.absoluteString ?? "(blank)" }
    public func title() -> String { webView.title ?? "" }

    // WKNavigationDelegate
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishNavigation()
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishNavigation()
    }
}

private func jsString(_ s: String) -> String {
    // JSON-encode as a JS string literal.
    if let data = try? JSONSerialization.data(withJSONObject: [s], options: []),
       let text = String(data: data, encoding: .utf8) {
        // text is ["..."], strip the brackets
        return String(text.dropFirst().dropLast())
    }
    return "\"\""
}

public struct BrowserNavigateTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "browser_navigate",
                 description: "Open a URL in the sandboxed browser (separate profile, no access to the user's own logins) and return the page title and address.",
                 inputSchema: JSONValue.schema([("url", "string", "http(s) URL")], required: ["url"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass {
        return WebFetchTool.classifyURL(input.string("url"))
    }

    public func describe(_ input: JSONValue) -> String {
        return "Open in sandbox browser: \(input.string("url") ?? "(none)")"
    }

    public func grantKey(_ input: JSONValue) -> String {
        let host = input.string("url").flatMap { URL(string: $0)?.host } ?? ""
        return "browser_navigate:\(host)"
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let s = input.string("url"), let url = URL(string: s) else { throw ToolError.invalidInput("a valid url is required") }
        await SandboxBrowser.shared.navigate(to: url)
        let title = await SandboxBrowser.shared.title()
        let current = await SandboxBrowser.shared.currentURL()
        return "Loaded: \(title)\n\(current)"
    }
}

public struct BrowserReadTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "browser_read",
                 description: "Return the visible text of the page currently open in the sandboxed browser.",
                 inputSchema: JSONValue.schema([], required: []))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass { .observe }
    public func describe(_ input: JSONValue) -> String { "Read the current page in the sandbox browser" }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        let text = try await SandboxBrowser.shared.evaluate("document.body ? document.body.innerText : ''")
        let title = await SandboxBrowser.shared.title()
        let url = await SandboxBrowser.shared.currentURL()
        return "Title: \(title)\nURL: \(url)\n\n" + text.truncated(to: 15_000)
    }
}

public struct BrowserLinksTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "browser_links",
                 description: "List up to 60 links (text and address) on the page currently open in the sandboxed browser.",
                 inputSchema: JSONValue.schema([], required: []))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass { .observe }
    public func describe(_ input: JSONValue) -> String { "List links on the current sandbox page" }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        let script = "Array.from(document.querySelectorAll('a[href]')).slice(0,60).map(a => (a.innerText||'').trim().slice(0,80) + ' -> ' + a.href).join('\\n')"
        return try await SandboxBrowser.shared.evaluate(script)
    }
}

public struct BrowserClickTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "browser_click",
                 description: "Click an element (CSS selector) on the current sandbox page. Clicking can submit forms or change accounts, so it needs the user's approval.",
                 inputSchema: JSONValue.schema([("selector", "string", "CSS selector of the element to click")], required: ["selector"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass { .change }

    public func describe(_ input: JSONValue) -> String {
        return "Click element '\(input.string("selector") ?? "")' on the page."
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let selector = input.string("selector") else { throw ToolError.invalidInput("selector is required") }
        let script = "(function(){var e=document.querySelector(\(jsString(selector)));if(!e){return 'not found';}e.click();return 'clicked';})()"
        return try await SandboxBrowser.shared.evaluate(script)
    }
}

public struct BrowserTypeTool: Tool {
    public init() {}

    public var spec: ToolSpec {
        ToolSpec(name: "browser_type",
                 description: "Type text into an input (CSS selector) on the current sandbox page. Needs the user's approval.",
                 inputSchema: JSONValue.schema([("selector", "string", "CSS selector of the input"), ("text", "string", "Text to enter")],
                                               required: ["selector", "text"]))
    }

    public func classify(_ input: JSONValue, context: ToolContext) -> ActionClass { .change }

    public func describe(_ input: JSONValue) -> String {
        return "Type \(input.string("text")?.count ?? 0) characters into '\(input.string("selector") ?? "")' on the page."
    }

    public func run(_ input: JSONValue, context: ToolContext) async throws -> String {
        guard let selector = input.string("selector"), let text = input.string("text") else {
            throw ToolError.invalidInput("selector and text are required")
        }
        let script = "(function(){var e=document.querySelector(\(jsString(selector)));if(!e){return 'not found';}e.focus();e.value=\(jsString(text));e.dispatchEvent(new Event('input',{bubbles:true}));return 'typed';})()"
        return try await SandboxBrowser.shared.evaluate(script)
    }
}
