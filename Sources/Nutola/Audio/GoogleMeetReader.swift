import AppKit
import ApplicationServices
import Foundation

enum GoogleMeetReader {
    static func scan(roomCode expectedRoom: String? = nil) -> GoogleMeetSnapshot? {
        guard AccessibilityPermission.isTrusted,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.1)
        let budget = ReadBudget()
        if let enabled = attribute(root, "AXEnhancedUserInterface", budget: budget) as? Bool, !enabled {
            // Chrome can apply this request even when the setter returns attributeUnsupported.
            AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        guard let value = attribute(root, "AXFocusedWindow", budget: budget),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = value as! AXUIElement

        func findMeeting(_ element: AXUIElement, depth: Int) -> (AXUIElement, String)? {
            guard depth < 40, budget.visit() else { return nil }
            if string(element, "AXRole", budget: budget) == "AXWebArea" {
                let value = attribute(element, "AXURL", budget: budget)
                let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                guard let url, let code = GoogleMeetSnapshot.roomCode(from: url) else { return nil }
                return (element, code)
            }
            for child in children(element, budget: budget) {
                if let meeting = findMeeting(child, depth: depth + 1) { return meeting }
            }
            return nil
        }
        guard let (webArea, code) = findMeeting(window, depth: 0) else { return nil }
        guard expectedRoom == nil || expectedRoom == code else { return nil }

        func snapshot(_ element: AXUIElement, depth: Int, collectContent: Bool = false) -> MeetAccessibilityNode? {
            guard depth < 40, budget.visit() else { return nil }
            var node = MeetAccessibilityNode(
                role: string(element, "AXRole", budget: budget) ?? "",
                subrole: string(element, "AXSubrole", budget: budget),
                title: string(element, "AXTitle", budget: budget),
                description: string(element, "AXDescription", budget: budget))
            let relevant = collectContent || node.isCaptionRegion || node.isParticipantList
            // Only caption/participant values in the pinned room are needed, never chat text.
            if relevant {
                node.value = string(element, "AXValue", budget: budget)
                node.identifier = String(CFHash(element))
            }
            node.children = children(element, budget: budget).compactMap {
                snapshot($0, depth: depth + 1, collectContent: relevant)
            }
            return node
        }
        guard let tree = snapshot(webArea, depth: 0), !budget.exhausted else { return nil }
        return GoogleMeetSnapshot.parse(tree, roomCode: code)
    }

    /// A slow or huge browser tree must not stall recording or yield a partial identity.
    private final class ReadBudget {
        private let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        private var count = 0
        private(set) var exhausted = false
        var available: Bool {
            if ProcessInfo.processInfo.systemUptime >= deadline { exhausted = true }
            return !exhausted
        }
        func visit() -> Bool {
            count += 1
            if count > 2_000 { exhausted = true }
            return available
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String, budget: ReadBudget) -> CFTypeRef? {
        guard budget.available else { return nil }
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String, budget: ReadBudget) -> String? {
        (attribute(element, name, budget: budget) as? String).map { String($0.prefix(4_000)) }
    }

    private static func children(_ element: AXUIElement, budget: ReadBudget) -> [AXUIElement] {
        (attribute(element, "AXChildren", budget: budget) as? [AXUIElement]) ?? []
    }
}
