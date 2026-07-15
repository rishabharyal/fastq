import Foundation

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case projects
    case tools
    case ready

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .projects: return "Projects"
        case .tools: return "Tools"
        case .ready: return "Ready"
        }
    }

    var progressIndex: Int { rawValue }

    var next: OnboardingStep? {
        OnboardingStep(rawValue: rawValue + 1)
    }

    var previous: OnboardingStep? {
        OnboardingStep(rawValue: rawValue - 1)
    }
}

struct DetectedToolPath: Identifiable, Hashable {
    var id: AgentToolKind { kind }
    var kind: AgentToolKind
    var path: String?
    var isInstalled: Bool { path != nil }
}
