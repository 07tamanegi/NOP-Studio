import SwiftUI
import AppKit

let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

/// エディタの種類。アセンブリは CPU 定義から命令名・レジスタ名を取ってハイライトする
enum EditorMode {
  case assembly(CPUSpec)
  case json
}

// MARK: - エディタ本体 (NSTextView を SwiftUI に埋め込む) ------------------------

struct CodeEditor: NSViewRepresentable {
  @Binding var text: String
  var errorLines: Set<Int> = []
  var activeLine: Int? = nil
  var mode: EditorMode
  
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSTextView.scrollableTextView()
    guard let textView = scroll.documentView as? NSTextView else { return scroll }
    
    textView.delegate = context.coordinator
    textView.isRichText = false
    textView.allowsUndo = true
    textView.font = editorFont
    textView.textContainerInset = NSSize(width: 4, height: 8)
    
    // コード向けに自動補正をすべて切る (JSON の " が “ ” に変わるのを防ぐ)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextCompletionEnabled = false
    textView.isAutomaticLinkDetectionEnabled = false
    textView.isAutomaticDataDetectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = false
    textView.isGrammarCheckingEnabled = false
    textView.smartInsertDeleteEnabled = false
    
    textView.string = text
    
    // 行番号ルーラー
    let ruler = LineNumberRuler(scrollView: scroll, orientation: .verticalRuler)
    ruler.clientView = textView
    scroll.verticalRulerView = ruler
    scroll.hasVerticalRuler = true
    scroll.rulersVisible = true
    scroll.contentView.postsBoundsChangedNotifications = true
    NotificationCenter.default.addObserver(ruler,
                                           selector: #selector(LineNumberRuler.redraw),
                                           name: NSView.boundsDidChangeNotification,
                                           object: scroll.contentView)
    
    context.coordinator.textView = textView
    context.coordinator.ruler = ruler
    context.coordinator.applyHighlight()
    return scroll
  }
  
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    let c = context.coordinator
    c.parent = self
    guard let tv = c.textView else { return }
    if tv.string != text {
      tv.string = text          // ファイルを開いたときなど外部からの変更
    }
    c.applyHighlight()
  }
  
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: CodeEditor
    weak var textView: NSTextView?
    weak var ruler: LineNumberRuler?
    private var lastActiveLine: Int?
    private var rules: [Highlighter.Rule] = []
    private var rulesKey = ""
    
    init(_ parent: CodeEditor) { self.parent = parent }
    
    func textDidChange(_ notification: Notification) {
      guard let tv = notification.object as? NSTextView else { return }
      parent.text = tv.string
      applyHighlight()
    }
    
    func applyHighlight() {
      guard let tv = textView else { return }
      ruler?.errorLines = parent.errorLines
      ruler?.activeLine = parent.activeLine
      ruler?.needsDisplay = true
      
      // 日本語入力の変換中に属性をいじると変換が壊れるのでスキップ
      if tv.hasMarkedText() { return }
      
      // CPU 定義が変わったときだけ正規表現を作り直す
      let key = Highlighter.key(for: parent.mode)
      if key != rulesKey {
        rules = Highlighter.rules(for: parent.mode)
        rulesKey = key
      }
      Highlighter.apply(to: tv, activeLine: parent.activeLine, rules: rules)
      
      // 実行中の行が変わったら、その行が見えるようにスクロール
      if let line = parent.activeLine, line != lastActiveLine,
         let r = Highlighter.rangeOfLine(line, in: tv.string as NSString) {
        tv.scrollRangeToVisible(r)
      }
      lastActiveLine = parent.activeLine
    }
  }
}

// MARK: - シンタックスハイライト ---------------------------------------------------

enum Highlighter {
  typealias Rule = (NSRegularExpression, NSColor)
  
  static func key(for mode: EditorMode) -> String {
    switch mode {
    case .assembly(let spec): return "asm:" + spec.highlightKey
    case .json:               return "json"
    }
  }
  
  /// 後ろのルールほど優先
  static func rules(for mode: EditorMode) -> [Rule] {
    var defs: [(String, NSColor, NSRegularExpression.Options)] = []
    let ci: NSRegularExpression.Options = [.caseInsensitive]
    
    switch mode {
    case .assembly(let spec):
      var mnemonics = spec.instructions.map { $0.name }
      if !spec.liSteps.isEmpty { mnemonics.append("LI") }
      let regs = spec.registers.map { $0.name }
      
      defs.append(("\\b(?:0x[0-9a-f]+|0b[01]+|\\d+)\\b", .systemOrange, ci))
      if !regs.isEmpty {
        defs.append(("\\b(?:" + regs.joined(separator: "|") + ")\\b", .systemTeal, ci))
      }
      if !mnemonics.isEmpty {
        defs.append(("\\b(?:" + mnemonics.joined(separator: "|") + ")\\b", .systemPink, ci))
      }
      defs.append(("\\.(?:byte|org)\\b", .systemIndigo, ci))
      defs.append(("^\\s*[A-Za-z_]\\w*(?=\\s*:)", .systemGreen, [.caseInsensitive, .anchorsMatchLines]))
      defs.append(("(?:;|//).*", .systemGray, ci))
      
    case .json:
      defs.append(("-?\\b\\d+\\b", .systemOrange, ci))
      defs.append(("\\b(?:true|false|null)\\b", .systemPink, ci))
      defs.append(("\"[^\"\\n]*\"", .systemGreen, ci))                    // 文字列
      defs.append(("\"[^\"\\n]*\"(?=\\s*:)", .systemBlue, ci))            // キー
    }
    
    return defs.compactMap { (item: (String, NSColor, NSRegularExpression.Options)) -> Rule? in
      guard let regex = try? NSRegularExpression(pattern: item.0, options: item.2) else { return nil }
      return (regex, item.1)
    }
  }
  
  static func apply(to tv: NSTextView, activeLine: Int?, rules: [Rule]) {
    guard let storage = tv.textStorage else { return }
    let string = storage.string
    let ns = string as NSString
    let full = NSRange(location: 0, length: ns.length)
    
    storage.beginEditing()
    storage.setAttributes([.font: editorFont, .foregroundColor: NSColor.textColor], range: full)
    for (regex, color) in rules {
      regex.enumerateMatches(in: string, options: [], range: full) { match, _, _ in
        if let r = match?.range {
          storage.addAttribute(.foregroundColor, value: color, range: r)
        }
      }
    }
    if let line = activeLine, let r = rangeOfLine(line, in: ns) {
      storage.addAttribute(.backgroundColor,
                           value: NSColor.systemYellow.withAlphaComponent(0.28),
                           range: r)
    }
    storage.endEditing()
    
    tv.typingAttributes = [.font: editorFont, .foregroundColor: NSColor.textColor]
  }
  
  /// 1始まりの行番号 → その行の NSRange
  static func rangeOfLine(_ line: Int, in ns: NSString) -> NSRange? {
    var current = 1
    var index = 0
    while index <= ns.length {
      let r = ns.lineRange(for: NSRange(location: index, length: 0))
      if current == line { return r.length > 0 ? r : nil }
      if NSMaxRange(r) >= ns.length { return nil }
      index = NSMaxRange(r)
      current += 1
    }
    return nil
  }
}

// MARK: - 行番号ルーラー ---------------------------------------------------------

final class LineNumberRuler: NSRulerView {
  var errorLines: Set<Int> = []
  var activeLine: Int? = nil
  
  override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
    super.init(scrollView: scrollView, orientation: orientation)
    ruleThickness = 44
    NotificationCenter.default.addObserver(self,
                                           selector: #selector(redraw),
                                           name: NSText.didChangeNotification,
                                           object: nil)
  }
  
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  override var isFlipped: Bool { true }
  
  @objc func redraw() {
    needsDisplay = true
  }
  
  override func drawHashMarksAndLabels(in rect: NSRect) {
    guard let tv = clientView as? NSTextView,
          let lm = tv.layoutManager,
          let tc = tv.textContainer else { return }
    
    // 背景と右端の区切り線
    NSColor.controlBackgroundColor.setFill()
    NSBezierPath.fill(bounds)
    NSColor.separatorColor.setFill()
    NSBezierPath.fill(NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height))
    
    let ns = tv.string as NSString
    let origin = tv.textContainerOrigin
    let visible = tv.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y)
    
    let glyphRange = lm.glyphRange(forBoundingRect: visible, in: tc)
    let charRange = lm.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    
    // 見えている先頭行の番号を求める
    let firstLineStart = ns.lineRange(for: NSRange(location: min(charRange.location, ns.length),
                                                   length: 0)).location
    var number = 1
    var scan = 0
    while scan < firstLineStart {
      scan = NSMaxRange(ns.lineRange(for: NSRange(location: scan, length: 0)))
      number += 1
    }
    
    let normal: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
      .foregroundColor: NSColor.secondaryLabelColor,
    ]
    let error: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
      .foregroundColor: NSColor.systemRed,
    ]
    let active: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold),
      .foregroundColor: NSColor.controlAccentColor,
    ]
    
    var index = firstLineStart
    while true {
      var lineRect: NSRect
      if index >= ns.length {
        // 末尾の空行 (最後が改行で終わる場合 / 空文書)
        lineRect = lm.extraLineFragmentRect
        if lineRect.isEmpty { break }
      } else {
        let glyph = lm.glyphIndexForCharacter(at: index)
        lineRect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
      }
      
      let y = convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: tv).y
      if y > bounds.height { break }
      
      let attrs = number == activeLine ? active : (errorLines.contains(number) ? error : normal)
      let label = "\(number)" as NSString
      let size = label.size(withAttributes: attrs)
      label.draw(at: NSPoint(x: bounds.width - size.width - 8,
                             y: y + (lineRect.height - size.height) / 2),
                 withAttributes: attrs)
      
      if number == activeLine {
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: 4, y: y + 4))
        tri.line(to: NSPoint(x: 10, y: y + lineRect.height / 2))
        tri.line(to: NSPoint(x: 4, y: y + lineRect.height - 4))
        tri.close()
        NSColor.controlAccentColor.setFill()
        tri.fill()
      }
      
      if index >= ns.length { break }
      index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
      number += 1
    }
  }
}
