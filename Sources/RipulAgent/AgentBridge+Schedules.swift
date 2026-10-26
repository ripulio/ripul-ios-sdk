import Foundation

/// Schedules that wake a chat (docs/plans/scheduled-agent-runs.md): Send Later,
/// the chat panel's list and the Schedules screen. The page reads and changes
/// them (`nativeCallables/schedules.ts`); every change made from here is a person's.
extension AgentBridge {

    /// Posted after this bridge made or changed a schedule, with the chat's id
    /// under `chatId` in its user info, so the chat panel shows it at once.
    public static let schedulesChangedNotification = Notification.Name("ripulSchedulesChanged")

    public struct ChatSchedule: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let brief: String
        /// `person` or `agent`.
        public let author: String
        public let paused: Bool
        /// `expired`, `failures` or `done` when it stopped by itself.
        public let endedReason: String?
        public let nextRunAt: Date?
        /// The time of its latest run, nil before the first.
        public let lastRunAt: Date?
        /// When it runs, in words: "Once", "Every 60 min", "Cron 7 9 * * 1-5".
        public let when: String
        /// The chat it wakes, by its id on the Mac that runs it; empty for a fresh schedule.
        public let targetChatId: String
        public let targetMachineId: String
        /// Starts a new agent for each run instead of waking a chat (phase 2).
        public let isFresh: Bool
        /// A fresh schedule's folder, model and effort.
        public let cwd: String?
        public let model: String?
        public let effort: String?
        /// What the last run left for the next one (schedule_report).
        public let lastNote: String?
        /// Runs on an event instead of a time (phase 3).
        public let isOnEvent: Bool
        /// The chat's title when the schedule was made; nil for older schedules.
        public let chatTitle: String?
        public let createdAt: Date?
        /// When an agent's schedule ends by itself; nil for a person's.
        public let expiresAt: Date?

        public var isLive: Bool { !paused && endedReason == nil }


        /// "When a web train fails", "On each critical observation".
        static func eventWords(_ rule: [String: Any]) -> String {
            let match = rule["match"] as? [String: Any] ?? [:]
            let list = { (key: String) in (match[key] as? [String] ?? []).joined(separator: " or ") }
            if rule["source"] as? String == "train" {
                let outcomes = (match["outcome"] as? [String] ?? []).map { ["failed": "fails", "shipped": "ships", "cancelled": "is cancelled"][$0] ?? $0 }
                let track = list("track")
                let article = track.first.map { "aeiou".contains($0.lowercased()) } == true ? "an" : "a"
                return "When \(track.isEmpty ? "a" : "\(article) \(track)") train \(outcomes.isEmpty ? "ends" : outcomes.joined(separator: " or "))"
            }
            let severity = list("severity")
            return "On each \(severity.isEmpty ? "" : "\(severity) ")observation"
        }

        /// Done, or ended after 7 days: nothing more will run.
        public var isFinished: Bool { endedReason == "done" || endedReason == "expired" }

        public var stateLabel: String {
            switch endedReason {
            case "done": return "Done"
            case "expired": return "Ended after 7 days"
            case "failures": return "Paused after three failures"
            default: return paused ? "Paused" : "Active"
            }
        }

        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? String, let name = raw["name"] as? String else { return nil }
            func date(_ key: String) -> Date? { (raw[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            self.id = id
            self.name = name
            self.brief = raw["brief"] as? String ?? ""
            self.author = raw["author"] as? String ?? "person"
            self.paused = raw["paused"] as? Bool ?? false
            self.endedReason = raw["endedReason"] as? String
            self.nextRunAt = date("nextAlarmAt")
            self.lastRunAt = date("lastPlannedAt")
            self.createdAt = date("createdAt")
            self.expiresAt = date("expiresAt")
            let target = raw["target"] as? [String: Any] ?? [:]
            self.targetChatId = target["chatId"] as? String ?? ""
            self.targetMachineId = target["machineId"] as? String ?? ""
            self.isFresh = target["kind"] as? String == "fresh"
            self.cwd = target["cwd"] as? String
            self.model = target["model"] as? String
            self.effort = target["effort"] as? String
            self.lastNote = ((raw["lastNote"] as? [String: Any])?["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            self.chatTitle = (raw["chatTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let rule = (raw["timing"] as? [String: Any])?["rule"] as? [String: Any] ?? [:]
            self.isOnEvent = rule["kind"] as? String == "event"
            switch rule["kind"] as? String {
            case "every": self.when = "Every \((rule["minutes"] as? Int) ?? 0) min"
            case "cron":
                let expression = rule["expression"] as? String ?? ""
                self.when = (rule["once"] as? Bool) == true ? "Once (cron \(expression))" : "Cron \(expression)"
            case "weekly":
                let times = (rule["times"] as? [String] ?? []).joined(separator: ", ")
                self.when = "Weekly at \(times)"
            case "event": self.when = Self.eventWords(rule)
            default: self.when = "Once"
            }
        }
    }

    /// One time a schedule ran, or should have.
    public struct ScheduleRun: Identifiable, Equatable {
        public let id: String
        /// The chat it went to: the woken chat, or a fresh run's own.
        public let chatId: String?
        /// Its place among the schedule's runs, from 1.
        public let number: Int?
        /// When it was due, before the schedule's spread.
        public let plannedAt: Date
        /// sending, waiting-for-mac, delivered, running, done, stopped, missed, skipped or failed.
        public let state: String
        public let startedAt: Date?
        public let endedAt: Date?
        /// quiet, found, failed or done, once its turn ended.
        public let outcome: String?
        /// The first words of the reply.
        public let summary: String?
        /// Why it was missed, skipped or not delivered.
        public let detail: String?
        /// What happened, for a run an event started: "train_3740 web failed at 0f4c7c7fd".
        public let eventTitle: String?

        public var stateLabel: String {
            switch state {
            case "sending": return "Sending"
            case "waiting-for-mac": return "Waiting for the Mac"
            case "delivered": return "Handed to the chat"
            case "running": return "Running"
            case "done":
                switch outcome {
                case "failed": return "Failed"
                case "found": return "Found something"
                case "quiet": return "Nothing to report"
                default: return "Done"
                }
            case "stopped": return "No end reported"
            case "missed": return "Missed"
            case "skipped": return "Skipped"
            case "failed": return "Not delivered"
            default: return state
            }
        }

        /// Ended badly: worth a look.
        public var isTrouble: Bool {
            state == "failed" || state == "missed" || state == "stopped" || outcome == "failed"
        }

        init?(_ raw: [String: Any]) {
            guard let id = raw["id"] as? String, let planned = raw["plannedAt"] as? Double,
                  let state = raw["state"] as? String else { return nil }
            func date(_ key: String) -> Date? { (raw[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
            self.id = id
            self.chatId = raw["chatId"] as? String
            self.number = raw["number"] as? Int
            self.plannedAt = Date(timeIntervalSince1970: planned / 1000)
            self.state = state
            self.startedAt = date("startedAt")
            self.endedAt = date("endedAt")
            self.outcome = raw["outcome"] as? String
            self.summary = (raw["summary"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            self.detail = raw["detail"] as? String
            self.eventTitle = (raw["event"] as? [String: Any])?["title"] as? String
        }
    }

    /// Send Later: this text goes into the chat once, at `at`, from a schedule
    /// the Ripul service keeps. `chatTitle` names the chat in the Schedules list.
    /// Returns an error to show, or nil when it is scheduled.
    public func scheduleMessage(chatId: String, text: String, at: Date, chatTitle: String? = nil) async -> String? {
        let reply = await callPage("__ripulScheduleMessage", [chatId, text, at.timeIntervalSince1970 * 1000, chatTitle],
                                   .orElse("{success:false, error:'Send Later is not available on this version of the app.'}"), log: .none)
        if let error = reply.error { return error.localizedDescription }
        guard reply.succeeded else { return reply.dictionary?["error"] as? String ?? "The message was not scheduled." }
        schedulesChanged(chatId)
        return nil
    }

    /// The schedules that wake this chat, live ones soonest first. Nil when the page could not say.
    public func getChatSchedules(chatId: String) async -> [ChatSchedule]? {
        let reply = await callPage("__ripulGetChatSchedules", [chatId], .orElse("{success:false, schedules:[]}"), log: .none)
        guard reply.succeeded, let list = reply.dictionary?["schedules"] as? [[String: Any]] else { return nil }
        return list.compactMap(ChatSchedule.init)
    }

    /// Every schedule on the account, whichever chat it wakes. Nil when the page could not say.
    public func getAllSchedules() async -> [ChatSchedule]? {
        let reply = await callPage("__ripulGetAllSchedules", [], .orElse("{success:false, schedules:[]}"), log: .none)
        guard reply.succeeded, let list = reply.dictionary?["schedules"] as? [[String: Any]] else { return nil }
        return list.compactMap(ChatSchedule.init)
    }

    /// A schedule's runs, newest first. Nil when the page could not say.
    public func getScheduleRuns(id: String) async -> [ScheduleRun]? {
        let reply = await callPage("__ripulGetScheduleRuns", [id], .orElse("{success:false, runs:[]}"), log: .none)
        guard reply.succeeded, let list = reply.dictionary?["runs"] as? [[String: Any]] else { return nil }
        return list.compactMap(ScheduleRun.init)
    }

    /// pause, resume, delete or run_now. Returns an error to show, or nil.
    public func changeSchedule(chatId: String, id: String, action: String) async -> String? {
        let reply = await callPage("__ripulChangeSchedule", [chatId, id, action],
                                   .orElse("{success:false, error:'Schedules are not available on this version of the app.'}"), log: .none)
        if let error = reply.error { return error.localizedDescription }
        guard reply.succeeded else { return reply.dictionary?["error"] as? String ?? "The schedule was not changed." }
        schedulesChanged(chatId)
        return nil
    }

    private func schedulesChanged(_ chatId: String) {
        NotificationCenter.default.post(name: Self.schedulesChangedNotification, object: self, userInfo: ["chatId": chatId])
    }
}
