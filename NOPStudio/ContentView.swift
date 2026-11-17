import SwiftUI

struct ContentView: View {
  @StateObject private var model = AssemblerModel()
  
  var body: some View {
    VStack(spacing: 0) {
      HSplitView {
        editorColumn
          .frame(minWidth: 380)
        sidePane
          .frame(minWidth: 480)
      }
      Divider()
      statusBar
    }
    .frame(minWidth: 1000, minHeight: 580)
    .navigationTitle(model.inputURL?.lastPathComponent ?? "無題")
    .navigationSubtitle(model.spec.name + (model.isDirty ? " — 編集済み" : ""))
    .toolbar {
      // 左: ファイルと CPU 定義
      ToolbarItemGroup(placement: .navigation) {
        Button { model.openSource() } label: {
          Label("開く", systemImage: "folder")
        }
        .keyboardShortcut("o", modifiers: .command)
        .help("アセンブリファイルを開く (⌘O)")
        
        Button { model.saveSource() } label: {
          Label("保存", systemImage: "square.and.arrow.down")
        }
        .keyboardShortcut("s", modifiers: .command)
        .help("保存 (⌘S)")
        
        Menu {
          Button("CPU 定義を開く…") { model.openSpecFile() }
          Button("CPU 定義を編集") { model.sideTab = .cpu }
          Button("CPU 定義を書き出し…") { model.saveSpecFile() }
          Divider()
          Button("標準の CPU に戻す") { model.resetSpecToDefault() }
        } label: {
          Label("CPU", systemImage: "cpu")
        }
        .help("CPU / ISA の定義ファイル")
      }
      
      // 右: エミュレータ操作と書き出し
      ToolbarItemGroup(placement: .primaryAction) {
        Button { model.resetAndShow() } label: {
          Label("リセット", systemImage: "arrow.counterclockwise")
        }
        .disabled(!model.canRun)
        .help("エミュレータをリセット")
        
        Button { model.stepCPU() } label: {
          Label("ステップ", systemImage: "forward.frame")
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(!model.canRun)
        .help("1命令だけ実行 (⌘T)")
        
        Button { model.runCPU() } label: {
          Label("実行", systemImage: "play.fill")
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!model.canRun)
        .help("停止するまで実行 (⌘R)")
        
        Button { model.export() } label: {
          Label("書き出し", systemImage: "square.and.arrow.up")
        }
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!model.canExport)
        .help("機械語をファイルに書き出す (⌘E)")
        
        Menu {
          Picker("出力形式", selection: $model.format) {
            ForEach(OutputFormat.allCases) { f in
              Text(f.label).tag(f)
            }
          }
          .pickerStyle(.inline)
          
          Divider()
          Button("出力先を選択…") { model.selectOutput() }
          Button("ソースを別名で保存…") { model.saveSource(asNew: true) }
        } label: {
          Label("出力設定", systemImage: "slider.horizontal.3")
        }
        .help("出力形式・出力先")
      }
    }
  }
  
  // MARK: エディタ側
  
  private var editorColumn: some View {
    VStack(spacing: 0) {
      CodeEditor(text: $model.source,
                 errorLines: model.errorLines,
                 activeLine: model.activeLine,
                 mode: .assembly(model.spec))
      
      if !model.result.errors.isEmpty {
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.result.errors.enumerated()), id: \.offset) { _, e in
              Label("行 \(e.line): \(e.message)",
                    systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .font(.callout)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(8)
        }
        .frame(maxHeight: 120)
        .background(Color(nsColor: .controlBackgroundColor))
      }
    }
  }
  
  // MARK: 右側 (タブ)
  
  private var sidePane: some View {
    VStack(spacing: 0) {
      Picker("", selection: $model.sideTab) {
        ForEach(SideTab.allCases) { tab in
          Text(tab.label).tag(tab)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(8)
      
      Divider()
      
      switch model.sideTab {
      case .listing:     ListingPane(model: model)
      case .emulator:    EmulatorPane(model: model)
      case .disassembly: DisassemblyPane(model: model)
      case .reference:   ReferencePane(spec: model.spec)
      case .cpu:         CPUSpecPane(model: model)
      }
    }
  }
  
  // MARK: ステータスバー
  
  private var statusBar: some View {
    HStack(spacing: 12) {
      Text(model.status.isEmpty ? "準備完了" : model.status)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      if let out = model.outputURL {
        Text("出力: \(out.lastPathComponent) (\(model.format.fileExtension))")
          .foregroundStyle(.secondary)
          .help(out.path)
      }
      Text("\(model.result.bytes.count) / \(model.spec.programSize) bytes")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
  }
}

#Preview {
  ContentView()
}
