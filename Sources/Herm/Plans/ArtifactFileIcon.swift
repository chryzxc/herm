import AppKit
import SwiftUI

/// Language-aware file icons from Material Icon Theme (MIT, bundled under
/// Resources/FileIcons). NSImage renders the SVGs natively on macOS 14+.
/// Nonisolated: the native Markdown builder resolves icons off the main actor.
enum ArtifactFileIcon {
    /// Exact file names win over extensions (package.json is Node, not JSON).
    static let fileNames: [String: String] = [
        "package.json": "nodejs", "package-lock.json": "npm", "yarn.lock": "yarn",
        "pnpm-lock.yaml": "pnpm", "bun.lockb": "bun", "tsconfig.json": "tsconfig",
        "dockerfile": "docker", "docker-compose.yml": "docker", "docker-compose.yaml": "docker",
        ".gitignore": "git", ".gitattributes": "git", ".env": "tune", ".editorconfig": "editorconfig",
        "makefile": "makefile", "readme.md": "readme", "license": "license", "license.md": "license",
        "changelog.md": "changelog", "gemfile": "gemfile", "build.gradle": "gradle",
        ".eslintrc": "eslint", ".eslintrc.json": "eslint", "eslint.config.js": "eslint",
        ".prettierrc": "prettier", "vite.config.ts": "vite", "vite.config.js": "vite",
        "tailwind.config.js": "tailwindcss", "tailwind.config.ts": "tailwindcss",
        "next.config.js": "next", "next.config.mjs": "next", "vercel.json": "vercel",
        "babel.config.js": "babel", "webpack.config.js": "webpack", "deno.json": "deno",
        "schema.prisma": "prisma", "taskfile.yml": "taskfile", "todo.md": "todo",
    ]

    /// Longest suffix wins, so `.test.ts` and `.d.ts` beat `.ts`.
    static let extensions: [String: String] = [
        "ts": "typescript", "mts": "typescript", "cts": "typescript", "d.ts": "typescript-def",
        "tsx": "react_ts", "jsx": "react", "js": "javascript", "mjs": "javascript", "cjs": "javascript",
        "test.ts": "test-ts", "spec.ts": "test-ts", "test.js": "test-js", "spec.js": "test-js",
        "test.tsx": "test-jsx", "test.jsx": "test-jsx", "js.map": "javascript-map", "css.map": "css-map",
        "py": "python", "ipynb": "jupyter", "swift": "swift", "go": "go", "rs": "rust",
        "java": "java", "kt": "kotlin", "kts": "kotlin", "c": "c", "h": "h", "cpp": "cpp", "cc": "cpp",
        "hpp": "hpp", "cs": "csharp", "m": "objective-c", "rb": "ruby", "php": "php", "dart": "dart",
        "lua": "lua", "r": "r", "scala": "scala", "ex": "elixir", "exs": "elixir", "erl": "erlang",
        "hs": "haskell", "zig": "zig", "nix": "nix", "jl": "julia", "pl": "perl", "clj": "clojure",
        "ml": "ocaml", "vue": "vue", "svelte": "svelte", "astro": "astro",
        "html": "html", "htm": "html", "css": "css", "scss": "sass", "sass": "sass", "less": "less",
        "json": "json", "jsonc": "json", "yaml": "yaml", "yml": "yaml", "toml": "toml", "xml": "xml",
        "xaml": "xaml", "md": "markdown", "markdown": "markdown", "mdx": "mdx", "tex": "tex",
        "graphql": "graphql", "gql": "graphql", "prisma": "prisma", "proto": "proto",
        "tf": "terraform", "sql": "database", "db": "database", "sqlite": "database",
        "sh": "console", "bash": "console", "zsh": "console", "fish": "console", "ps1": "powershell",
        "env": "tune", "ini": "settings", "conf": "settings", "cfg": "settings", "lock": "lock",
        "log": "log", "http": "http", "pem": "certificate", "crt": "certificate", "key": "key",
        "pdf": "pdf", "txt": "document", "rtf": "document", "doc": "word", "docx": "word",
        "ppt": "powerpoint", "pptx": "powerpoint", "csv": "table", "tsv": "table", "xls": "table",
        "xlsx": "table", "zip": "zip", "gz": "zip", "tar": "zip", "tgz": "zip", "7z": "zip",
        "svg": "svg", "png": "image", "jpg": "image", "jpeg": "image", "gif": "image", "webp": "image",
        "heic": "image", "ico": "image", "lottie": "lottie", "mp3": "audio", "wav": "audio",
        "m4a": "audio", "mp4": "video", "mov": "video", "webm": "video", "ttf": "font", "otf": "font",
        "woff": "font", "woff2": "font", "dmg": "disc", "iso": "disc", "exe": "exe", "apk": "android",
        "gradle": "gradle", "mat": "matlab",
    ]

    /// Language names reuse the bundled file glyphs; aliases cover names that differ from icon keys.
    static let languageAliases: [String: String] = [
        "c++": "cpp", "c#": "csharp", "objective-c++": "objective-c", "shell": "console",
        "jupyter notebook": "jupyter", "dockerfile": "docker", "makefile": "makefile",
        "scss": "sass", "powershell": "powershell", "hcl": "terraform", "tex": "tex",
    ]

    static func name(forLanguage language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let alias = languageAliases[normalized] { return alias }
        if let icon = extensions[normalized] { return icon }
        return extensions.values.contains(normalized) ? normalized : fallback
    }

    static func image(forLanguage language: String) -> NSImage? {
        image(named: name(forLanguage: language))
    }

    static let fallback = "document"

    static func name(for fileName: String) -> String {
        mappedName(for: fileName) ?? fallback
    }

    /// The icon for a known file name or extension; nil for anything else.
    static func mappedName(for fileName: String) -> String? {
        let lower = fileName.lowercased()
        if let match = fileNames[lower] { return match }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false)
        // Try ".test.ts" before ".ts"; skip index 0 (the base name).
        for start in parts.indices.dropFirst() {
            if let match = extensions[parts[start...].joined(separator: ".")] { return match }
        }
        if lower.hasPrefix(".env") { return "tune" }
        return nil
    }

    /// Icon for free text that names a file (`src/app.ts`, `README.md`), or
    /// nil for prose and code such as `npm run build` or `config.set`.
    static func mappedName(forPath text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 260,
            !trimmed.contains(where: \.isWhitespace)
        else { return nil }
        let fileName = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        return mappedName(for: fileName)
    }

    private static let bundle = Bundle.herm

    // NSCache is thread-safe; images are read-only once cached.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()

    static func image(for fileName: String) -> NSImage? {
        image(named: name(for: fileName))
    }

    /// Fixed-size icon for inline text, or nil when `text` isn't a file.
    static func inlineImage(forPath text: String, size: CGFloat) -> NSImage? {
        guard let key = mappedName(forPath: text), let base = image(named: key) else { return nil }
        let cacheKey = "\(key)@\(size)" as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        guard let sized = base.copy() as? NSImage else { return nil }
        sized.size = NSSize(width: size, height: size)
        cache.setObject(sized, forKey: cacheKey)
        return sized
    }

    private static func image(named key: String) -> NSImage? {
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let url = bundle.url(forResource: key, withExtension: "svg", subdirectory: "FileIcons"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// The file's type icon on a tile, for rows and cards that name one file.
struct FileTypeIcon: View {
    let fileName: String
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let image = ArtifactFileIcon.image(for: fileName) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                DockIcon(.file, size: size * 0.5, color: .dockSecondaryText)
            }
        }
        .dockPadding(size * 0.18)
        .frame(width: size, height: size)
        .background(
            RoundedRectangle(cornerRadius: DockLayout.controlRadius - 1, style: .continuous).dockSurfaceFill(
                Color.dockSurface2)
        )
        .accessibilityHidden(true)
    }
}

extension Text {
    /// Markdown text with a file icon before each inline-code or link run
    /// that names a file, and `@bot` mentions in plain runs drawn as pills.
    /// Text with neither keeps the plain `Text(value)` path.
    @MainActor static func withFileIcons(_ value: AttributedString, iconSize: CGFloat) -> Text {
        func isCodeOrLink(_ run: AttributedString.Runs.Run) -> Bool {
            run.link != nil || run.inlinePresentationIntent?.contains(.code) == true
        }
        func icon(_ run: AttributedString.Runs.Run) -> NSImage? {
            guard isCodeOrLink(run) else { return nil }
            return ArtifactFileIcon.inlineImage(forPath: String(value[run.range].characters), size: iconSize)
        }
        let hasMentions = !BotMentions.matches(in: String(value.characters)).isEmpty
        guard hasMentions || value.runs.contains(where: { icon($0) != nil }) else { return Text(value) }
        return value.runs.reduce(Text("")) { text, run in
            guard isCodeOrLink(run) else { return text + Text.withMentionPills(value[run.range]) }
            let piece = Text(AttributedString(value[run.range]))
            guard let image = icon(run) else { return text + piece }
            return text + Text(Image(nsImage: image)).baselineOffset(-2) + Text("\u{2009}") + piece
        }
    }
}
