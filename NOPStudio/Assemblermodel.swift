import SwiftUI
import AppKit
import Combine

enum SideTab: String, CaseIterable, Identifiable {
  case listing, emulator, disassembly, reference, cpu
  
  var id: String { rawValue }
  
  var label: String {
    switch self {
    case .listing:     return "リスト"
    case .emulator:    return "実行"
    case .disassembly: return "逆アセンブル"
    case .reference:   return "リファレンス"
    case .cpu:         return "CPU定義"
    }
  }
}

/// アプリの状態 (ソース・CPU 定義・ファイル設定・アセンブル結果・エミュレータ) とファイル操作
final class AssemblerModel: ObservableObject {
  
  static let sampleSource = """
    ; acc を 5 から 0 までカウントダウンして停止するサンプル
            LI   5            ; R0 = 5  (LUI 5 / LLI 0 に展開)
            MOV  acc, r0      ; acc = 5
    loop:
            DEC               ; acc -= 1
            JZ   done         ; zero flag が 1 なら done へ (R0 を使う)
            JMP  loop
    done:
            JMP  done         ; 停止
    """
  
  // MARK: 状態
  
  /// ソースが変わるたびに自動でアセンブルし直し、エラーがなければエミュレータもリセットする
  @Published var source: String {
    didSet {
      result = assemble(source, spec: spec)
      isDirty = true
      if result.errors.isEmpty { resetCPU() }
    }
  }
  @Published private(set) var result: AssemblyResult
  @Published private(set) var isDirty = false
  
  // CPU 定義
  @Published private(set) var spec: CPUSpec
  @Published var specText: String                       // エディタで編集中のテキスト
  @Published private(set) var appliedSpecText: String   // 最後に適用に成功したテキスト
  @Published private(set) var specError: String? = nil
  @Published private(set) var specURL: URL? = nil
  
  // ファイル設定
  @Published var inputURL: URL? = nil
  @Published var outputURL: URL? = nil
  @Published var format: OutputFormat {
    didSet {
      UserDefaults.standard.set(format.rawValue, forKey: "outputFormat")
      // 出力形式を変えたら、拡張子の合わない出力先は破棄する
      if oldValue != format, outputURL != nil {
        outputURL = nil
        status = "出力形式を変更したので、出力先をリセットしました"
      }
    }
  }
  
  @Published var status: String = ""
  @Published var sideTab: SideTab = .listing
  
  // エミュレータ
  @Published private(set) var cpu: Emulator
  @Published var sharedMemory: Bool {
    didSet { if oldValue != sharedMemory { resetCPU() } }
  }
  
  // 逆アセンブル
  @Published private(set) var disasmRows: [DisasmRow] = []
  @Published private(set) var disasmTitle = ""
  
  init() {
    // CPU 定義: 前回適用したものがあればそれ、なければ内蔵の標準
    var loadedSpec = CPUSpec.empty
    var loadedText = CPUSpec.defaultJSON
    var initialError: String? = nil
    if let saved = UserDefaults.standard.string(forKey: "cpuSpecJSON"),
       let s = try? CPUSpec.parse(json: saved) {
      loadedSpec = s
      loadedText = saved
    } else {
      let b = CPUSpec.builtin()
      loadedSpec = b.spec
      initialError = b.error
    }
    
    let initial = AssemblerModel.sampleSource
    let r = assemble(initial, spec: loadedSpec)
    
    spec = loadedSpec
    specText = loadedText
    appliedSpecText = loadedText
    source = initial
    result = r
    sharedMemory = loadedSpec.sharedMemoryDefault
    cpu = Emulator(program: r.bytes, shared: loadedSpec.sharedMemoryDefault, spec: loadedSpec)
    let savedFormat = UserDefaults.standard.string(forKey: "outputFormat") ?? ""
    format = OutputFormat(rawValue: savedFormat) ?? .bin
    
    if let e = initialError {
      specError = e
      status = e
    }
  }
  
  // MARK: 派生値
  
  var canExport: Bool { result.errors.isEmpty }
  var canRun: Bool { result.errors.isEmpty && !spec.instructions.isEmpty }
  var errorLines: Set<Int> { Set(result.errors.map { $0.line }) }
  var specTextChanged: Bool { specText != appliedSpecText }
  
  /// エミュレータタブを開いているとき、次に実行される命令のソース行
  var activeLine: Int? {
    guard sideTab == .emulator, canRun else { return nil }
    return result.rows.first { $0.addr == Int(cpu.pc) }?.line
  }
  
  // MARK: CPU 定義
  
  /// specText を検証して適用する。失敗したら現在の定義のまま、エラーを表示する
  func applySpecText() {
    do {
      let s = try CPUSpec.parse(json: specText)
      install(s, text: specText)
      specError = nil
      status = "CPU 定義「\(s.name)」を適用しました"
    } catch let e as SpecError {
      specError = e.message
      status = "CPU 定義にエラーがあります"
    } catch {
      specError = error.localizedDescription
      status = "CPU 定義にエラーがあります"
    }
  }
  
  private func install(_ s: CPUSpec, text: String) {
    spec = s
    appliedSpecText = text
    UserDefaults.standard.set(text, forKey: "cpuSpecJSON")
    
    result = assemble(source, spec: s)
    sharedMemory = s.sharedMemoryDefault
    resetCPU()
    disasmRows = []
    disasmTitle = ""
  }
  
  func openSpecFile() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    
    do {
      specText = try String(contentsOf: url, encoding: .utf8)
      specURL = url
      sideTab = .cpu
      applySpecText()
    } catch {
      specError = "読み込みに失敗しました: \(error.localizedDescription)"
      status = "CPU 定義を読み込めません"
    }
  }
  
  func saveSpecFile() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = specURL?.lastPathComponent ?? "cpu.json"
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let dest = panel.url else { return }
    
    do {
      try specText.write(to: dest, atomically: false, encoding: .utf8)
      specURL = dest
      status = "CPU 定義を書き出しました: \(dest.lastPathComponent)"
    } catch {
      status = "CPU 定義の書き出しに失敗しました: \(error.localizedDescription)"
    }
  }
  
  func resetSpecToDefault() {
    specText = CPUSpec.defaultJSON
    specURL = nil
    applySpecText()
  }
  
  // MARK: エミュレータ操作
  
  func resetCPU() {
    cpu = Emulator(program: result.bytes, shared: sharedMemory, spec: spec)
  }
  
  func resetAndShow() {
    guard canRun else { return }
    resetCPU()
    sideTab = .emulator
  }
  
  func stepCPU() {
    guard canRun else { return }
    sideTab = .emulator
    cpu.step()
  }
  
  func runCPU() {
    guard canRun else { return }
    sideTab = .emulator
    if cpu.haltReason != nil { resetCPU() }   // 停止済みなら最初からやり直す
    var c = cpu
    c.run()
    cpu = c
  }
  
  // MARK: 入力ファイル
  
  func openSource() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    
    do {
      let text = try String(contentsOf: url, encoding: .utf8)
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
      inputURL = url
      source = text
      isDirty = false
      status = "\(url.lastPathComponent) を開きました"
    } catch {
      status = "読み込みに失敗しました: \(error.localizedDescription)"
    }
  }
  
  func saveSource(asNew: Bool = false) {
    var target = inputURL
    if target == nil || asNew {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = inputURL?.lastPathComponent ?? "program.asm"
      panel.canCreateDirectories = true
      guard panel.runModal() == .OK else { return }
      target = panel.url
    }
    guard let dest = target else { return }
    
    do {
      try source.write(to: dest, atomically: false, encoding: .utf8)
      inputURL = dest
      isDirty = false
      status = "\(dest.lastPathComponent) を保存しました"
    } catch {
      status = "保存に失敗しました: \(error.localizedDescription)"
    }
  }
  
  // MARK: 出力ファイル
  
  private var defaultOutputName: String {
    let base = inputURL?.deletingPathExtension().lastPathComponent ?? "program"
    return base + "." + format.fileExtension
  }
  
  private func askOutputURL() -> URL? {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = defaultOutputName
    panel.canCreateDirectories = true
    panel.allowsOtherFileTypes = true
    return panel.runModal() == .OK ? panel.url : nil
  }
  
  /// 出力先だけ決める (書き出しはしない)
  func selectOutput() {
    if let url = askOutputURL() {
      outputURL = url
      status = "出力先: \(url.path)"
    }
  }
  
  /// 出力先が未設定なら選択ダイアログを出し、決まったら書き出す
  func export() {
    guard canExport else {
      status = "エラーがあるため書き出せません"
      return
    }
    guard let dest = outputURL ?? askOutputURL() else { return }
    
    do {
      try formatOutput(result.bytes, format: format).write(to: dest)
      outputURL = dest
      status = "\(result.bytes.count) バイトを書き出しました: \(dest.path)"
    } catch {
      status = "書き出しに失敗しました: \(error.localizedDescription)"
    }
  }
  
  // MARK: 逆アセンブル
  
  func openBinaryForDisassembly() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    
    do {
      let data = try Data(contentsOf: url)
      let bytes = Disassembler.parseFile(data: data, fileExtension: url.pathExtension)
      disasmRows = Disassembler.disassemble(bytes, spec: spec)
      disasmTitle = "\(url.lastPathComponent) — \(bytes.count) バイト"
      sideTab = .disassembly
      status = "\(url.lastPathComponent) を逆アセンブルしました"
    } catch {
      status = "読み込みに失敗しました: \(error.localizedDescription)"
    }
  }
  
  func showCurrentDisassembly() {
    disasmRows = Disassembler.disassemble(result.bytes, spec: spec)
    disasmTitle = "現在のアセンブル結果 — \(result.bytes.count) バイト"
    sideTab = .disassembly
  }
}
