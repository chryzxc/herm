import Foundation

enum AssistantDay: Equatable {
    case today, tomorrow
    case weekday(Int)

    init?(_ spoken: String) {
        switch spoken.lowercased() {
        case "today": self = .today
        case "tomorrow": self = .tomorrow
        default:
            let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            guard let index = weekdays.firstIndex(of: spoken.lowercased()) else { return nil }
            self = .weekday(index + 1)
        }
    }

    func interval(now: Date, calendar: Calendar) -> DateInterval? {
        let offset: Int
        switch self {
        case .today: offset = 0
        case .tomorrow: offset = 1
        case .weekday(let day): offset = (day - calendar.component(.weekday, from: now) + 7) % 7
        }
        guard let date = calendar.date(byAdding: .day, value: offset, to: now) else { return nil }
        return calendar.dateInterval(of: .day, for: date)
    }
}

enum AssistantDayPart: String, Equatable {
    case morning, afternoon, evening

    var hours: Range<Int> {
        switch self {
        case .morning: 9..<12
        case .afternoon: 12..<17
        case .evening: 17..<21
        }
    }

    func interval(on day: DateInterval, calendar: Calendar) -> DateInterval? {
        guard let start = calendar.date(bySettingHour: hours.lowerBound, minute: 0, second: 0, of: day.start),
            let end = calendar.date(bySettingHour: hours.upperBound, minute: 0, second: 0, of: day.start)
        else { return nil }
        return DateInterval(start: start, end: end)
    }
}

enum AssistantChannel: String, Codable, CaseIterable {
    case mail, messages

    var title: String { self == .mail ? "Mail" : "Messages" }
}

/// Launching a browser app is not a request for Hermes to open or control a page.
enum AssistantBrowserApp: String {
    case systemDefault
    case chrome = "com.google.Chrome"
    case safari = "com.apple.Safari"
    case firefox = "org.mozilla.firefox"
    case edge = "com.microsoft.edgemac"
    case brave = "com.brave.Browser"

    var displayName: String {
        switch self {
        case .systemDefault: "your default browser"
        case .chrome: "Google Chrome"
        case .safari: "Safari"
        case .firefox: "Firefox"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        }
    }

    static func parse(_ speech: String) -> Self? {
        let text = AssistantIntent.normalized(speech)
            .trimmingCharacters(in: .punctuationCharacters)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard
            var name = AssistantIntent.match(
                #"^(?:(?:please|(?:can|could|would) you)(?: please)? )?(?:open|launch|start) (.+)$"#, text)?.first
        else { return nil }

        var external = false
        if let boundary = name.range(
            of: #"(?:, *| +)(?:outside (?:of )?|not (?:in|inside) )(?:the )?herm(?: app)?$"#,
            options: .regularExpression)
        {
            name.removeSubrange(boundary)
            external = true
        }
        name = name.replacing(/^(?:a|an|the|my)\s/, with: "")
        if let modifier = name.range(of: #"^(?:separate|standalone|external) "#, options: .regularExpression) {
            name.removeSubrange(modifier)
            external = true
        }
        name = name.replacing(/\s(?:app|application|window)$/, with: "")
        switch name {
        case "default browser", "default web browser": return .systemDefault
        case "browser", "web browser": return external ? .systemDefault : nil
        default: break
        }

        switch name.replacing(/\sbrowser$/, with: "") {
        case "chrome", "google chrome": return .chrome
        case "safari": return .safari
        case "firefox", "mozilla firefox": return .firefox
        case "edge", "microsoft edge": return .edge
        case "brave": return .brave
        default: return nil
        }
    }
}

enum AssistantIntent: Equatable {
    case timerCreate(name: String?, seconds: Int)
    case timers
    case timerRemaining(String?)
    case timerExtend(String?, seconds: Int)
    case timerCancel(String?)
    case calendarNext
    case calendarAgenda(AssistantDay)
    case calendarFree(AssistantDay, AssistantDayPart)
    case calendarBlock(AssistantDay, AssistantDayPart, seconds: Int, title: String)
    case reminder(title: String, list: String?, due: AssistantDay?)
    case open(String)
    case launchBrowser(AssistantBrowserApp)
    case map(String)
    case time(String?)
    case calculation(String)
    case shortcut(String)
    case approvals
    case activity(sinceLunch: Bool)
    case task(title: String, board: String?)
    case message(AssistantChannel, to: String, subject: String?, body: String, draftOnly: Bool)
    case help(String)

    static func parse(_ spoken: String) -> Self? {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "’", with: "'")
        let textWithoutPunctuation = text.trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        if let place = match(
            #"^(?:(?:please|can you|could you) )?(?:(?:show|bring up|display|open)(?: me)? (?:a |the )?(?:(?:street|road) )?)?map (?:of|for) (.+)$"#,
            textWithoutPunctuation)?.first, !place.isEmpty, place.count <= 160
        {
            return .map(place)
        }
        return communication(spoken.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? timer(textWithoutPunctuation) ?? work(textWithoutPunctuation)
            ?? organizer(textWithoutPunctuation) ?? mac(textWithoutPunctuation)
    }

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func timer(_ text: String) -> Self? {
        let line = normalized(text)
        if ["list timers", "list my timers", "show my timers", "what timers are running"].contains(line) {
            return .timers
        }
        if let groups = match(
            #"^(?:set|start) (?:a |an )?(?:(.+?) )?timer for (.+?)(?: (?:called|named) (.+))?$"#, text),
            let seconds = duration(groups[1])
        {
            return .timerCreate(name: nonempty(groups[2]) ?? nonempty(groups[0]), seconds: seconds)
        }
        if let groups = match(
            #"^(?:how long (?:is )?(?:left|remaining)(?: on (?:my |the )?(.+?)(?: timer)?)?|check (?:my |the )?(.+?)(?: timer)?)$"#,
            text),
            groups[1].isEmpty || line.contains("timer")
        {
            return .timerRemaining(nonempty(groups[0]) ?? nonempty(groups[1]))
        }
        if let groups = match(
            #"^add (.+?)(?: to (?:my |the )?(.*?)(?: timer)?)?$"#, text),
            let seconds = duration(groups[0])
        {
            return .timerExtend(nonempty(groups[1]), seconds: seconds)
        }
        if let groups = match(#"^extend (?:(?:my |the )?(.+?) )?timer by (.+)$"#, text),
            let seconds = duration(groups[1])
        {
            return .timerExtend(nonempty(groups[0]), seconds: seconds)
        }
        if let groups = match(#"^cancel (?:my |the )?(?:(.+?) )?timer$"#, text) {
            return .timerCancel(nonempty(groups[0]))
        }
        if line.contains("timer"), ["set ", "start ", "extend ", "cancel ", "add "].contains(where: line.hasPrefix) {
            return .help("Say a duration and the timer’s name, or say “list my timers.”")
        }
        return nil
    }

    private static func organizer(_ text: String) -> Self? {
        let line = normalized(text)
        if ["what's next on my calendar", "what is next on my calendar", "what's next", "what is next"].contains(line) {
            return .calendarNext
        }
        if let groups = match(
            #"^(?:what(?:'s| is) on|show(?: me)?) my calendar(?: (?:for |on )?(\w+))?$"#, text)
        {
            return AssistantDay(groups[0].isEmpty ? "today" : groups[0]).map(Self.calendarAgenda)
                ?? .help("Which day? Try today, tomorrow, or a weekday.")
        }
        if let groups = match(#"^when am i free (?:this |(\w+) )(morning|afternoon|evening)$"#, text),
            let day = AssistantDay(groups[0].isEmpty ? "today" : groups[0]),
            let part = AssistantDayPart(rawValue: groups[1].lowercased())
        {
            return .calendarFree(day, part)
        }
        if let groups = match(#"^block (.+?) (today|tomorrow|\w+) (morning|afternoon|evening) for (.+)$"#, text),
            let seconds = duration(groups[0]), let day = AssistantDay(groups[1]),
            let part = AssistantDayPart(rawValue: groups[2].lowercased())
        {
            return .calendarBlock(day, part, seconds: seconds, title: groups[3])
        }
        if line.hasPrefix("block ") {
            return .help("Say how long, which day and part of the day, and what the calendar block is for.")
        }
        if let groups = match(
            #"^add (.+?) to (?:my |the )?(.+?)(?: list| reminders)(?: due (today|tomorrow|\w+))?$"#, text),
            !normalized(groups[1]).hasSuffix("board")
        {
            if !groups[2].isEmpty, AssistantDay(groups[2]) == nil {
                return .help("Say today, tomorrow, or a weekday for the reminder’s due date.")
            }
            return .reminder(title: groups[0], list: groups[1], due: AssistantDay(groups[2]))
        }
        if let groups = match(
            #"^(?:add|create) (?:a )?reminder (?:to |for )?(.+?)(?: due (today|tomorrow|\w+))?$"#, text)
        {
            return .reminder(title: groups[0], list: nil, due: AssistantDay(groups[1]))
        }
        return nil
    }

    private static func work(_ text: String) -> Self? {
        switch normalized(text) {
        case "what needs my approval", "what needs approval": return .approvals
        case "what finished today": return .activity(sinceLunch: false)
        case "what changed since lunch": return .activity(sinceLunch: true)
        default: break
        }
        if let groups = match(#"^add (.+?) to (?:my task|the (.+?)|my (.+?)) board$"#, text) {
            return .task(title: groups[0], board: nonempty(groups[1]) ?? nonempty(groups[2]))
        }
        return nil
    }

    private static func communication(_ text: String) -> Self? {
        if let groups = match(
            #"^(draft|send) (?:a |an )?(message|text|email) to (.+?)(?: subject (.+?))? saying (.+)$"#, text)
        {
            let channel: AssistantChannel = normalized(groups[1]) == "email" ? .mail : .messages
            return .message(
                channel, to: groups[2], subject: nonempty(groups[3]), body: groups[4],
                draftOnly: normalized(groups[0]) == "draft")
        }
        if match(#"^(?:send|draft) (?:a |an )?(?:message|text|email)(?: |$)"#, text) != nil {
            return .help("Say who it is for and what to say. For email, you can include a subject.")
        }
        return nil
    }

    private static func mac(_ text: String) -> Self? {
        if let browser = AssistantBrowserApp.parse(text) { return .launchBrowser(browser) }
        if let groups = match(#"^open (.+)$"#, text), VoicePrompts.revealedTab(text) == nil {
            return .open(groups[0])
        }
        if let groups = match(#"^what time is it(?: in (.+))?$"#, text) {
            return .time(nonempty(groups[0]))
        }
        if let groups = match(#"^(?:run (?:my |the )?(?:shortcut )?|start my )(.+)$"#, text) {
            let name = groups[0]
            if normalized(text).hasPrefix("run shortcut ")
                || AssistantShortcutPreferences.shortcut(matching: name) != nil
            {
                return .shortcut(name)
            }
        }
        if AssistantMath.recognizes(text), normalized(text).hasPrefix("convert ") { return .calculation(text) }
        if let groups = match(#"^(?:calculate |what(?:'s| is) )(.+)$"#, text),
            AssistantMath.recognizes(groups[0])
        {
            return .calculation(groups[0])
        }
        if let groups = match(#"^how many (.+) (?:are )?in (.+)$"#, text),
            AssistantMath.recognizesConversion(target: groups[0], source: groups[1])
        {
            return .calculation("convert " + groups[1] + " to " + groups[0])
        }
        return nil
    }

    static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).map { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
    }

    static func nonempty(_ text: String) -> String? { text.isEmpty ? nil : text }

    static func number(_ text: String) -> Decimal? {
        let text = normalized(text)
        if let encoded = match(#"^(-?\d+(?:\.\d+)?)$"#, text)?.first,
            let result = Decimal(string: encoded, locale: Locale(identifier: "en_US_POSIX"))
        {
            return result
        }
        let small = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        ]
        if text == "a" || text == "an" { return 1 }
        if let index = small.firstIndex(of: text) { return Decimal(index) }
        let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        let terms = text.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard (1...2).contains(terms.count), let index = tens.firstIndex(of: terms[0]) else { return nil }
        if terms.count == 1 { return Decimal((index + 2) * 10) }
        guard let units = small.firstIndex(of: terms[1]), (1...9).contains(units) else { return nil }
        return Decimal((index + 2) * 10 + units)
    }

    private static func duration(_ text: String) -> Int? {
        guard let groups = match(#"^(.+?) (seconds?|minutes?|hours?)$"#, text),
            let count = number(groups[0]), count > 0
        else { return nil }
        let unit = groups[1].lowercased()
        let seconds = count * (unit.hasPrefix("hour") ? 3600 : unit.hasPrefix("minute") ? 60 : 1)
        guard seconds >= 1, seconds <= 86_400 else { return nil }
        return NSDecimalNumber(decimal: seconds).intValue
    }
}

enum AssistantMath {
    private static let units: [String: (category: String, base: Decimal)] = [
        "mm": ("length", 0.001), "millimeters": ("length", 0.001), "centimeters": ("length", 0.01),
        "centimetres": ("length", 0.01), "cm": ("length", 0.01), "meters": ("length", 1),
        "metres": ("length", 1), "m": ("length", 1), "km": ("length", 1000), "kilometers": ("length", 1000),
        "inches": ("length", 0.0254), "feet": ("length", 0.3048), "miles": ("length", 1609.344),
        "grams": ("mass", 1), "kilograms": ("mass", 1000), "kg": ("mass", 1000),
        "pounds": ("mass", 453.59237), "ounces": ("mass", 28.349523125),
        "seconds": ("time", 1), "minutes": ("time", 60), "hours": ("time", 3600),
        "milliliters": ("volume", 1), "liters": ("volume", 1000),
    ]

    private static let arithmetic = #"^(.+?)\s*(percent of|% of|plus|minus|times|divided by|\+|-|\*|/)\s*(.+)$"#

    static func recognizes(_ expression: String) -> Bool {
        if expression.lowercased().hasPrefix("convert ") { return true }
        guard let groups = AssistantIntent.match(arithmetic, expression) else { return false }
        return AssistantIntent.number(groups[0]) != nil && AssistantIntent.number(groups[2]) != nil
    }

    static func recognizesConversion(target: String, source: String) -> Bool {
        unit(target) != nil && measured(source) != nil
    }

    static func answer(_ expression: String) -> String? {
        if let groups = AssistantIntent.match(#"^convert (.+) to (.+)$"#, expression),
            let (number, source) = measured(groups[0]), let target = unit(groups[1])
        {
            guard source.category == target.category else { return "Those units measure different things." }
            return "\(formatted(number * source.base / target.base)) \(groups[1])."
        }
        guard let groups = AssistantIntent.match(arithmetic, expression),
            let left = AssistantIntent.number(groups[0]), let right = AssistantIntent.number(groups[2])
        else { return nil }
        switch groups[1].lowercased() {
        case "percent of", "% of": return formatted(left * right / 100)
        case "plus", "+": return formatted(left + right)
        case "minus", "-": return formatted(left - right)
        case "times", "*": return formatted(left * right)
        default: return right == 0 ? "Division by zero is undefined." : formatted(left / right)
        }
    }

    private static func unit(_ text: String) -> (category: String, base: Decimal)? {
        let word = AssistantIntent.normalized(text)
        if word == "foot" { return units["feet"] }
        return units[word] ?? units[word + (word.hasSuffix("ch") ? "es" : "s")]
    }

    private static func measured(_ text: String) -> (Decimal, (category: String, base: Decimal))? {
        if let groups = AssistantIntent.match(#"^(.+?) (\w+)$"#, text),
            let amount = AssistantIntent.number(groups[0]), let unit = unit(groups[1])
        {
            return (amount, unit)
        }
        return unit(text).map { (1, $0) }
    }

    private static func formatted(_ value: Decimal) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }
}
