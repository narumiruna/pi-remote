import Foundation

public struct ExtensionDisplayState: Codable, Sendable, Equatable {
    public var statuses: [ExtensionStatus]
    public var widgets: [ExtensionWidget]
    public var notices: [ExtensionNotice]

    public init(statuses: [ExtensionStatus] = [], widgets: [ExtensionWidget] = [], notices: [ExtensionNotice] = []) {
        self.statuses = statuses; self.widgets = widgets; self.notices = notices
    }
}

public struct ExtensionStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String

    public init(id: String, text: String) {
        self.id = id; self.text = text
    }
}

public enum ExtensionWidgetPlacement: String, Codable, Sendable {
    case aboveEditor, belowEditor
}

public struct ExtensionWidget: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var placement: ExtensionWidgetPlacement

    public init(id: String, text: String, placement: ExtensionWidgetPlacement = .aboveEditor) {
        self.id = id; self.text = text; self.placement = placement
    }
}

public enum ExtensionNoticeSeverity: String, Codable, Sendable {
    case info, warning, error
}

public struct ExtensionNotice: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    public var severity: ExtensionNoticeSeverity

    public init(id: String, text: String, severity: ExtensionNoticeSeverity = .info) {
        self.id = id; self.text = text; self.severity = severity
    }
}
