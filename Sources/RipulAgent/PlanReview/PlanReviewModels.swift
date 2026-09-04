import SwiftUI

/// Decoded shapes for the plan review screen.
///
/// These mirror the view models built by `planRepoService.buildPlanDetailView`
/// in the web app. Native decodes and renders them; it deliberately does **not**
/// re-derive lock state, re-resolve anchors, or decide which status moves are
/// legal. Those rules live in one place (`src/plans/planState.ts`) and two
/// implementations in two languages drift — the first symptom being a screen
/// that says "locked" while the tools say otherwise.
///
/// Every enum carries an `unknown` case so a newer web build adding a severity
/// or status cannot make an older app fail to decode a whole plan.

/// A failure with a message meant for the screen, not a log.
///
/// Every plan-review failure — an unreachable machine, a plan that is not in
/// the working directory, an illegal status transition — arrives as one of
/// these, because from the user's side they are all the same thing: a sentence
/// explaining why nothing happened.
public struct PlanReviewError: Error, LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

// MARK: - Vocabulary

public enum PlanSeverity: String, Codable, Sendable {
    case blocking
    case shouldFix = "should-fix"
    case nit
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlanSeverity(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .blocking: return "Blocking"
        case .shouldFix: return "Should fix"
        case .nit: return "Nit"
        case .unknown: return "Comment"
        }
    }

    var symbol: String {
        switch self {
        case .blocking: return "exclamationmark.octagon.fill"
        case .shouldFix: return "exclamationmark.triangle.fill"
        case .nit: return "text.bubble"
        case .unknown: return "bubble.left"
        }
    }

    var tint: Color {
        switch self {
        case .blocking: return .red
        case .shouldFix: return .orange
        case .nit: return .secondary
        case .unknown: return .secondary
        }
    }
}

public enum PlanCommentStatus: String, Codable, Sendable {
    case open
    case accepted
    case resolved
    case wontfix
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlanCommentStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .open: return "Open"
        case .accepted: return "Accepted"
        case .resolved: return "Resolved"
        case .wontfix: return "Won't fix"
        case .unknown: return "—"
        }
    }

    var symbol: String {
        switch self {
        case .open: return "circle"
        case .accepted: return "checkmark.circle"
        case .resolved: return "checkmark.circle.fill"
        case .wontfix: return "slash.circle"
        case .unknown: return "questionmark.circle"
        }
    }
}

public enum PlanTaskStatus: String, Codable, Sendable {
    case open
    case doing
    case done
    case dropped
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlanTaskStatus(rawValue: raw) ?? .unknown
    }

    var isDone: Bool { self == .done }
}

// MARK: - Models

public struct PlanReply: Codable, Identifiable, Sendable {
    public let id: String
    public let author: String
    public let body: String
    public let ts: String
}

public struct PlanComment: Codable, Identifiable, Sendable {
    public let id: String
    public let anchor: String
    public let severity: PlanSeverity
    public let status: PlanCommentStatus
    public let author: String
    public let body: String
    public let createdAt: String
    public let orphaned: Bool
    public let suggestion: String?
    public let replies: [PlanReply]
    public let taskIds: [String]
    /// Which status moves the web layer will accept. Empty means closed —
    /// the screen offers no actions rather than offering one that will bounce.
    public let allowedActions: [PlanCommentStatus]

    private enum CodingKeys: String, CodingKey {
        case id, anchor, severity, status, author, body, createdAt
        case orphaned, suggestion, replies, taskIds, allowedActions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        anchor = try c.decode(String.self, forKey: .anchor)
        severity = try c.decode(PlanSeverity.self, forKey: .severity)
        status = try c.decode(PlanCommentStatus.self, forKey: .status)
        author = try c.decode(String.self, forKey: .author)
        body = try c.decode(String.self, forKey: .body)
        createdAt = try c.decode(String.self, forKey: .createdAt)
        orphaned = try c.decodeIfPresent(Bool.self, forKey: .orphaned) ?? false
        suggestion = try c.decodeIfPresent(String.self, forKey: .suggestion)
        replies = try c.decodeIfPresent([PlanReply].self, forKey: .replies) ?? []
        taskIds = try c.decodeIfPresent([String].self, forKey: .taskIds) ?? []
        // Drop anything this build does not understand rather than failing.
        let actions = try c.decodeIfPresent([PlanCommentStatus].self, forKey: .allowedActions) ?? []
        allowedActions = actions.filter { $0 != .unknown }
    }
}

/// A section you can address, whether or not it carries comments.
/// `PlanDetail.sections` is what gets rendered; this is what gets picked.
public struct PlanAnchor: Codable, Identifiable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let heading: String
    public let level: Int
}

public struct PlanSection: Codable, Identifiable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let heading: String
    public let level: Int
    /// The section's own markdown. Rendered so the screen shows the plan, not
    /// just commentary about it.
    public let prose: String
    public let comments: [PlanComment]

    private enum CodingKeys: String, CodingKey { case slug, heading, level, prose, comments }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        heading = try c.decode(String.self, forKey: .heading)
        level = try c.decode(Int.self, forKey: .level)
        prose = try c.decodeIfPresent(String.self, forKey: .prose) ?? ""
        comments = try c.decodeIfPresent([PlanComment].self, forKey: .comments) ?? []
    }
}

public struct PlanTask: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let status: PlanTaskStatus
    public let owner: String?
    public let fromComment: String?
}

public struct PlanViolation: Codable, Identifiable, Sendable {
    public var id: String { eventId ?? "line-\(line ?? 0)-\(reason)" }
    public let eventId: String?
    public let line: Int?
    public let reason: String
    public let detail: String
}

public struct PlanDetail: Codable, Identifiable, Sendable {
    public var id: String { slug }
    public let slug: String
    public let title: String
    public let bodyPath: String
    /// The session↔plan link key (`plan:<slug>@<hash6>`), computed web-side —
    /// never derived here. Optional: an older web bundle may not send it.
    public let planKey: String?
    public let machineName: String
    public let bodyMissing: Bool
    /// True while the body is still the creation template — a plan with a
    /// title nobody has written yet. Drives the "draft" affordances.
    public let bodyIsTemplate: Bool
    /// The raw markdown source, whole — the file as agent runs read it.
    /// Optional: absent on older web bundles.
    public let body: String?
    public let locked: Bool
    public let blockingOutstanding: Int
    public let openBlocking: Int
    public let openShouldFix: Int
    public let openNit: Int
    public let planComments: [PlanComment]
    public let sections: [PlanSection]
    /// Markdown before the first heading.
    public let intro: String
    public let anchors: [PlanAnchor]
    public let orphaned: [PlanComment]
    public let closed: [PlanComment]
    public let tasks: [PlanTask]
    public let violations: [PlanViolation]

    private enum CodingKeys: String, CodingKey {
        case slug, title, bodyPath, planKey, machineName, bodyMissing, bodyIsTemplate, body, locked
        case blockingOutstanding, openBlocking, openShouldFix, openNit
        case planComments, sections, intro, anchors, orphaned, closed, tasks, violations
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        bodyPath = try c.decode(String.self, forKey: .bodyPath)
        planKey = try c.decodeIfPresent(String.self, forKey: .planKey)
        machineName = try c.decode(String.self, forKey: .machineName)
        bodyMissing = try c.decode(Bool.self, forKey: .bodyMissing)
        bodyIsTemplate = try c.decodeIfPresent(Bool.self, forKey: .bodyIsTemplate) ?? false
        body = try c.decodeIfPresent(String.self, forKey: .body)
        locked = try c.decode(Bool.self, forKey: .locked)
        blockingOutstanding = try c.decode(Int.self, forKey: .blockingOutstanding)
        openBlocking = try c.decode(Int.self, forKey: .openBlocking)
        openShouldFix = try c.decode(Int.self, forKey: .openShouldFix)
        openNit = try c.decode(Int.self, forKey: .openNit)
        planComments = try c.decodeIfPresent([PlanComment].self, forKey: .planComments) ?? []
        sections = try c.decodeIfPresent([PlanSection].self, forKey: .sections) ?? []
        intro = try c.decodeIfPresent(String.self, forKey: .intro) ?? ""
        anchors = try c.decodeIfPresent([PlanAnchor].self, forKey: .anchors) ?? []
        orphaned = try c.decodeIfPresent([PlanComment].self, forKey: .orphaned) ?? []
        closed = try c.decodeIfPresent([PlanComment].self, forKey: .closed) ?? []
        tasks = try c.decodeIfPresent([PlanTask].self, forKey: .tasks) ?? []
        violations = try c.decodeIfPresent([PlanViolation].self, forKey: .violations) ?? []
    }

    /// Everything still owed, for the header count.
    var outstandingCount: Int {
        planComments.count + sections.reduce(0) { $0 + $1.comments.count } + orphaned.count
    }

    var openTasks: [PlanTask] { tasks.filter { $0.status == .open || $0.status == .doing } }
}

/// A run start's outcome: nil error = started. `chatId` is the new session —
/// the checkpoint records it as the plan's author session for draft/address
/// runs, so the kick path never has to re-derive identity from titles.
public struct PlanRunStartResult: Sendable {
    public let error: String?
    public let chatId: String?
    public init(error: String?, chatId: String?) {
        self.error = error
        self.chatId = chatId
    }
}

/// The Plans folder selector's state, computed web-side (`planWorkingDirectoryState`).
public extension WorkScopeState {
    /// The picker's title, identical on every surface.
    /// Mirrors `WORK_SCOPE_TITLE` in `workScope.ts`.
    static let title = "Work in"

    /// One sentence describing where the effective folder came from.
    ///
    /// Shared so all four surfaces word provenance the same way. Plans used to
    /// say "Chosen for Plans", which stopped being true the moment the sessions
    /// list started writing the same value. Mirrors `workScopeCaption`.
    var caption: String {
        let machine = machineName.map { " · \($0)" } ?? ""
        switch source {
        case "chosen": return "Chosen\(machine)"
        case "chat": return "Following the active chat\(machine)"
        case "machine-default": return "Machine default\(machine)"
        default: return "No folder resolves — pick one"
        }
    }

    /// Fold locally-discovered folders into the picker's options.
    ///
    /// Machine dirs keep their order and stay first; discovered paths follow,
    /// sorted and deduped. Callers must pass only paths belonging to
    /// `machineName` — scope overrides the DIRECTORY and leaves the machine
    /// implicit, so a path from another machine resolves against the wrong disk.
    /// Mirrors `mergeScopeOptions`.
    func mergedOptions(discovered: [String]) -> [String] {
        let known = Set(options)
        let extra = Set(discovered.filter { !$0.isEmpty && !known.contains($0) })
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return options + extra
    }
}

public struct WorkScopeState: Codable, Sendable {
    /// The directory plans currently resolve against; nil when nothing does.
    public let effective: String?
    /// Provenance: "chosen" | "chat" | "machine-default" | "none".
    public let source: String
    /// The machine's default + favorite directories, for the picker.
    public let options: [String]
    public let machineName: String?
}

/// Where a plan is in its life, resolved web-side by `planLifecycleState`.
///
/// The row's glyph, tint AND subtitle all key off this. They used to be three
/// independent switch statements over the raw booleans below, which is how this
/// list grew to five states while the web list still had three.
///
/// Decoding never fails on an unrecognised value. Web deploys continuously and
/// native ships on OTA cadence, so a state added web-side reaches installed
/// builds before they know the case exists; `drafted` is the safest under-claim
/// (it implies neither "not started" nor "locked"), and one row rendered
/// generically beats a `DecodingError` that blanks the whole list.
public enum PlanLifecycleState: String, Codable, Sendable {
    case template
    case drafted
    case openFindings = "open-findings"
    case lockedWithTasks = "locked-with-tasks"
    case lockedClean = "locked-clean"

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = PlanLifecycleState(rawValue: raw) ?? .drafted
    }
}

// Hashable so `navigationDestination(item:)` can drive the push from a row —
// identity is the composite id below, not the whole value.
public struct PlanListEntry: Codable, Identifiable, Sendable, Hashable {
    /// Identity is (root, slug), not slug alone.
    ///
    /// The list spans projects now, and `docs/plans/auth.md` in two repos is two
    /// different plans. Keying on slug would give `ForEach` duplicate ids and
    /// make a selection or a tap land on whichever row happened to be first.
    public var id: String { root.map { "\($0)/\(slug)" } ?? slug }

    public static func == (lhs: PlanListEntry, rhs: PlanListEntry) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public let slug: String
    public let title: String
    public let locked: Bool
    public let blockingOutstanding: Int
    public let openComments: Int
    public let openTasks: Int
    /// False when nobody has reviewed this plan yet — distinct from "locked".
    public let hasLog: Bool
    /// Lifecycle state, computed web-side. Additive: every field above stays on
    /// the wire, because the subtitle needs the raw counts and because dropping
    /// one would throw here rather than degrade.
    public let state: PlanLifecycleState
    /// Newest log-event timestamp (ISO-8601), computed web-side. Nil before
    /// anything has happened — and absent entirely on older web bundles,
    /// which is why it decodes as optional.
    public let lastActiveAt: String?
    /// Still the creation template — a plan with a title nobody has written.
    /// Optional: absent on older web bundles.
    public let bodyIsTemplate: Bool?
    /// The directory this plan was found in, absolute on the resolved machine.
    ///
    /// The list spans projects now, so every action goes back to the plan's OWN
    /// root rather than to the work scope — otherwise editing a plan you can
    /// see would write to whichever repo the scope happens to point at.
    /// Optional: absent on older web bundles, which then behave as before.
    public let root: String?
    /// The root's last path component — what the project filter groups by.
    public let projectName: String?
    /// The session↔plan link key, for session-aware list decoration.
    public let planKey: String?
    /// Session-metadata row id holding this plan's USER tags — repo-qualified,
    /// and deliberately NOT `planKey` (that key has no repo component, so two
    /// repos with `docs/plans/auth.md` would share one tag set). The list joins
    /// its bulk tag map against this; nothing native derives it.
    /// Optional: absent on older web bundles, which simply means no lozenges.
    public let tagsId: String?

    private enum CodingKeys: String, CodingKey {
        case slug, title, locked, blockingOutstanding, openComments, openTasks
        case hasLog, state, lastActiveAt, bodyIsTemplate, planKey, tagsId
        case root, projectName
    }

    /// Hand-written so a MISSING `state` key degrades instead of throwing —
    /// the mirror of the unknown-value case above, and the one that bites on a
    /// web rollback below the deploy that added the field.
    ///
    /// Deliberately does NOT re-derive the state from the booleans when absent.
    /// A local derivation is exactly the second decoder this field exists to
    /// delete; a transient window of under-claimed rows is the cheaper failure.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        title = try c.decode(String.self, forKey: .title)
        locked = try c.decode(Bool.self, forKey: .locked)
        blockingOutstanding = try c.decode(Int.self, forKey: .blockingOutstanding)
        openComments = try c.decode(Int.self, forKey: .openComments)
        openTasks = try c.decode(Int.self, forKey: .openTasks)
        hasLog = try c.decode(Bool.self, forKey: .hasLog)
        state = try c.decodeIfPresent(PlanLifecycleState.self, forKey: .state) ?? .drafted
        lastActiveAt = try c.decodeIfPresent(String.self, forKey: .lastActiveAt)
        bodyIsTemplate = try c.decodeIfPresent(Bool.self, forKey: .bodyIsTemplate)
        planKey = try c.decodeIfPresent(String.self, forKey: .planKey)
        tagsId = try c.decodeIfPresent(String.self, forKey: .tagsId)
        root = try c.decodeIfPresent(String.self, forKey: .root)
        projectName = try c.decodeIfPresent(String.self, forKey: .projectName)
    }
}

// MARK: - Actions

/// One human action, mirroring the agent tool surface.
///
/// Encoded to the dictionary `__ripulPlanReviewAct` expects. Kept as an enum so
/// the call sites cannot assemble a half-populated action.
public enum PlanAction: Sendable {
    case comment(anchor: String, severity: PlanSeverity, body: String)
    case reply(commentId: String, body: String)
    case status(commentId: String, status: PlanCommentStatus, note: String?)
    case task(title: String, fromComment: String?, owner: String?)
    case taskStatus(taskId: String, status: PlanTaskStatus)

    func payload(author: String) -> [String: Any] {
        switch self {
        case let .comment(anchor, severity, body):
            return ["kind": "comment", "anchor": anchor, "severity": severity.rawValue,
                    "body": body, "author": author]
        case let .reply(commentId, body):
            return ["kind": "reply", "commentId": commentId, "body": body, "author": author]
        case let .status(commentId, status, note):
            var p: [String: Any] = ["kind": "status", "commentId": commentId,
                                    "status": status.rawValue, "author": author]
            if let note, !note.isEmpty { p["note"] = note }
            return p
        case let .task(title, fromComment, owner):
            var p: [String: Any] = ["kind": "task", "title": title, "author": author]
            if let fromComment { p["fromComment"] = fromComment }
            if let owner, !owner.isEmpty { p["owner"] = owner }
            return p
        case let .taskStatus(taskId, status):
            return ["kind": "task-status", "taskId": taskId,
                    "status": status.rawValue, "author": author]
        }
    }
}
