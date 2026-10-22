import AppKit
import Charts
import SwiftUI

struct RichDocumentView: View {
  let document: RichDocument
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(document.segments.enumerated()), id: \.offset) { _, segment in
        switch segment {
        case .markdown(let text): MarkdownMessageView(markdown: text).equatable()
        case .surface(let surface, let source): RichSurfaceView(surface: surface, source: source)
        case .unavailable(let text, let source):
          Text(text).foregroundStyle(Color.dockSecondaryText).textSelection(.enabled)
          RichSourceDisclosure(source: source)
        case .pending:
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Preparing interactive view…").foregroundStyle(Color.dockSecondaryText)
          }.dockFont(.body).frame(minHeight: 44)
        }
      }
    }
  }
}

struct RichSurfaceView: View {
  let surface: RichSurface
  let source: String
  @State private var standaloneIdentity = UUID()
  @Environment(\.richReplyState) private var state
  @Environment(\.richReplyContext) private var context
  @ObservedObject private var htmlCoordinator = GeneratedHTMLCoordinator.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(surface.title).dockFont(size: 12, weight: .semibold).foregroundStyle(
        Color.dockPrimaryText)
      if surface.kind == .html {
        Text(surface.fallback).dockFont(.body).foregroundStyle(Color.dockSecondaryText)
        if htmlCoordinator.activeKey == htmlKey, let html = surface.html {
          GeneratedHTMLPreview(html: html, identity: htmlKey)
        } else {
          Button("Open interactive view") { htmlCoordinator.open(htmlKey) }.buttonStyle(.dockSecondary)
        }
      } else {
        ForEach(Array((surface.blocks ?? []).enumerated()), id: \.offset) { index, block in
          blockView(block, index: index)
        }
      }
      RichSourceDisclosure(source: source)
    }
    .padding(.vertical, 8)
    .dockFont(.body)
    .frame(maxWidth: .infinity, alignment: .leading)
    .onDisappear { if htmlCoordinator.activeKey == htmlKey { htmlCoordinator.close() } }
  }

  private var htmlKey: String { "\(key):\(standaloneIdentity)" }

  private var key: String {
    "\(context?.sourceKey ?? standaloneIdentity.uuidString):\(surface.id):\(context?.revision ?? source.hashValue)"
  }

  @ViewBuilder
  private func blockView(_ block: RichBlock, index: Int) -> some View {
    switch block.type {
    case .text:
      Text(block.text ?? "").textSelection(.enabled).foregroundStyle(Color.dockPrimaryText)
    case .table: RichTableView(columns: block.columns ?? [], rows: block.rows ?? [])
    case .sources:
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
          if let url = RichResourcePolicy.url(item.url) {
            Button {
              InAppBrowser.open(url)
            } label: {
              DockIconLabel(item.title, icon: .arrowSquareOut)
            }.buttonStyle(.dockLink)
          }
        }
      }
    case .gallery:
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], alignment: .leading, spacing: 12
      ) {
        ForEach(Array((block.items ?? []).enumerated()), id: \.offset) { _, item in
          VStack(alignment: .leading, spacing: 6) {
            if let url = RichResourcePolicy.url(item.url, image: true) {
              if url.scheme == "data" {
                AttachmentThumbnailView(url: url).frame(height: 160)
              } else {
                // Remote assets use the established session browser; no background fetch from generated URLs.
                Button {
                  InAppBrowser.open(url)
                } label: {
                  VStack(spacing: 8) {
                    DockIcon(.image, size: 24, color: .dockSecondaryText)
                    DockIconLabel("Open image", icon: .arrowSquareOut)
                  }.frame(maxWidth: .infinity, minHeight: 120)
                }.buttonStyle(.dockSecondary)
              }
              Text(item.title).foregroundStyle(Color.dockSecondaryText).lineLimit(2)
            }
          }
        }
      }
    case .chart:
      Chart(Array((block.points ?? []).enumerated()), id: \.offset) { _, point in
        if block.style == "line" {
          LineMark(x: .value("Category", point.label), y: .value("Value", point.value))
            .foregroundStyle(Color.dockAccent)
          PointMark(x: .value("Category", point.label), y: .value("Value", point.value))
            .foregroundStyle(Color.dockAccent)
        } else {
          BarMark(x: .value("Category", point.label), y: .value("Value", point.value))
            .foregroundStyle(Color.dockAccent)
        }
      }
      .chartXAxis { AxisMarks { _ in AxisValueLabel().foregroundStyle(Color.dockMetadataText) } }
      .chartYAxis {
        AxisMarks(position: .leading) { _ in
          AxisGridLine().foregroundStyle(Color.dockBorderLight)
          AxisValueLabel().foregroundStyle(Color.dockMetadataText)
        }
      }
      .frame(height: 164)
      .padding(.top, 4)
      .accessibilityLabel(surface.title)
    case .form:
      if let state, let context {
        RichFormView(
          surface: surface, block: block, context: context,
          draft: state.form(key: "\(key):\(index)"))
      } else {
        Text(surface.fallback).foregroundStyle(Color.dockSecondaryText)
        Text("Forms require a session conversation.").foregroundStyle(Color.dockMetadataText)
      }
    }
  }
}

struct RichSourceDisclosure: View {
  let source: String
  @State private var expanded = false
  var body: some View {
    if !source.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Button {
          expanded.toggle()
        } label: {
          DockIconLabel(
            expanded ? "Hide source" : "View source", icon: expanded ? .caretDown : .caretRight)
        }.buttonStyle(.dockLink)
        if expanded {
          DockCopyButton(
            source, label: "Copy source", accessibilityLabel: "Copy interactive source"
          ).buttonStyle(.dockCompact)
          ScrollView([.horizontal, .vertical]) {
            Text(source).dockFont(size: 12, design: .monospaced).textSelection(.enabled)
              .foregroundStyle(Color.dockSecondaryText).frame(
                maxWidth: .infinity, alignment: .leading)
          }.frame(maxHeight: 220)
        }
      }
    }
  }
}

private struct RichTableView: View {
  let columns: [String]
  let rows: [[String]]
  var body: some View {
    GeometryReader { geometry in
      ScrollView([.horizontal, .vertical]) {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 0) {
          GridRow {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, value in
              Text(value).fontWeight(.medium).foregroundStyle(Color.dockSecondaryText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
            }
          }
          Color.dockBorder.frame(height: DockLayout.hairline).gridCellColumns(max(1, columns.count))
          ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            GridRow {
              ForEach(Array(row.enumerated()), id: \.offset) { _, value in
                Text(value).textSelection(.enabled).foregroundStyle(Color.dockPrimaryText)
                  .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9)
              }
            }
            if index < rows.count - 1 {
              Color.dockBorderLight.frame(height: DockLayout.hairline).gridCellColumns(
                max(1, columns.count))
            }
          }
        }.frame(minWidth: geometry.size.width, alignment: .leading)
      }
    }
    .frame(height: min(320, CGFloat(rows.count + 1) * 34 + 2))
  }
}

private struct RichFormView: View {
  let surface: RichSurface
  let block: RichBlock
  let context: RichReplyContext
  @ObservedObject var draft: RichFormDraft
  private var fields: [RichField] { block.fields ?? [] }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(fields) { field in
        VStack(alignment: .leading, spacing: 6) {
          Text(field.label + (field.required == true ? " · Required" : ""))
            .foregroundStyle(Color.dockSecondaryText)
          fieldView(field)
        }
      }
      Button {
        Task { await context.submit(draft, surface: surface, fields: fields) }
      } label: {
        HStack(spacing: 6) {
          if draft.pending { ProgressView().controlSize(.small) }
          Text(draft.sent ? "Answer sent" : block.submitLabel ?? "Send answer")
        }
      }.buttonStyle(.dockPrimary)
        .disabled(
          draft.pending || draft.sent || !context.isCurrent
            || draft.submission?.delivery == .needsReview)
      if !context.isCurrent {
        Text("Open the unchanged source message to answer this form.").foregroundStyle(
          Color.dockSecondaryText)
      }
      if let error = draft.error {
        Text(error).foregroundStyle(Color.dockWarning).textSelection(.enabled)
      }
    }.disabled(draft.pending || draft.sent)
  }

  private func string(_ field: RichField) -> Binding<String> {
    Binding(
      get: { draft.values[field.id]?.first ?? "" },
      set: { draft.values[field.id] = [String($0.prefix(8_192))] })
  }
  @ViewBuilder
  private func fieldView(_ field: RichField) -> some View {
    switch field.type {
    case .text, .number:
      TextField(field.type == .number ? "Number" : "Your answer", text: string(field))
        .textFieldStyle(.dockGlass)
        .accessibilityLabel(field.label)
    case .choice:
      Picker(field.label, selection: string(field)) {
        Text("Choose…").tag("")
        ForEach(field.options ?? [], id: \.self) { option in Text(option).tag(option) }
      }.labelsHidden().pickerStyle(.menu)
    case .multipleChoice:
      ForEach(field.options ?? [], id: \.self) { option in
        Toggle(
          option,
          isOn: Binding(
            get: { draft.values[field.id, default: []].contains(option) },
            set: { selected in
              var values = draft.values[field.id, default: []]
              values.removeAll { $0 == option }
              if selected { values.append(option) }
              draft.values[field.id] = values
            })
        ).toggleStyle(.checkbox)
      }
    case .boolean:
      Toggle(
        field.label,
        isOn: Binding(
          get: { draft.values[field.id] == ["Yes"] },
          set: {
            draft.values[field.id] = [$0 ? "Yes" : "No"]
          })
      ).toggleStyle(.dockSwitch)
    }
  }
}
