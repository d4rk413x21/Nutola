import CoreGraphics
import EventKit
import Foundation
import SwiftUI

struct CalendarSourceInfo: Identifiable, Equatable {
    var id: String
    var title: String
    var sourceTitle: String?
    var color: Color
}

enum CalendarSources {
    static func all() -> [CalendarSourceInfo] {
        guard CalendarAuthorization.isAuthorized else { return [] }
        return EKEventStore().calendars(for: .event)
            .map { calendar in
                CalendarSourceInfo(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title,
                    color: Color(cgColor: calendar.cgColor))
            }
            .sorted {
                let left = ($0.sourceTitle ?? "", $0.title)
                let right = ($1.sourceTitle ?? "", $1.title)
                return left < right
            }
    }

    static func enabledEKCalendars(in store: EKEventStore) -> [EKCalendar]? {
        guard CalendarAuthorization.isAuthorized else { return [] }
        let all = store.calendars(for: .event)
        let disabled = AppSettings.disabledCalendarIDs
        guard !disabled.isEmpty else { return nil }
        let enabled = all.filter { calendar in
            !disabled.contains(calendar.calendarIdentifier)
        }
        return enabled
    }
}

extension CalendarColor {
    init(cgColor: CGColor) {
        if let rgb = cgColor.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
           let components = rgb.components, components.count >= 3 {
            red = Double(components[0])
            green = Double(components[1])
            blue = Double(components[2])
            alpha = components.count >= 4 ? Double(components[3]) : 1
        } else {
            self = .gray
        }
    }

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
