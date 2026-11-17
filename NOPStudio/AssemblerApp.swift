import Foundation

// 命令セット・レジスタ・メモリサイズは CPUSpec (CPU 定義ファイル) から与えられる。
// ここにはアセンブラの処理だけが入っている。

let pseudoOps: Set<String> = ["LI", ".BYTE", ".ORG"]

// MARK: - 型 ---------------------------------------------------------------

struct AsmError: Error {
  let line: Int
  let message: String
}

struct ListingRow: Identifiable {
  let addr: Int
  let byte: UInt8
  let source: String?     // 複数バイトに展開された命令では先頭バイトだけ持つ
  let line: Int           // ソース上の行番号 (1始まり)。エミュレータの実行行表示に使う
  var id: Int { addr }
}

struct AssemblyResult {
  var bytes: [UInt8] = []
  var rows: [ListingRow] = []
  var errors: [AsmError] = []
}

struct Line {
  let number: Int
  let source: String
  var label: String?
  var op: String?          // 大文字化したニーモニック / ディレクティブ
  var args: [String]
}

enum OutputFormat: String, CaseIterable, Identifiable {
  case bin, hex, logisim
  
  var id: String { rawValue }
  
  var label: String {
    switch self {
    case .bin:     return "バイナリ (.bin)"
    case .hex:     return "16進テキスト (.hex)"
    case .logisim: return "Logisim (.rom)"
    }
  }
  
  var fileExtension: String {
    switch self {
    case .bin:     return "bin"
    case .hex:     return "hex"
    case .logisim: return "rom"
    }
  }
}

// MARK: - 字句解析 -----------------------------------------------------------

func isIdentifier(_ s: String) -> Bool {
  guard let first = s.first, first.isLetter || first == "_" else { return false }
  return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
}

func parseNumber(_ s: String) -> Int? {
  var t = s.lowercased()
  var negative = false
  if t.hasPrefix("-") { negative = true; t.removeFirst() }
  let value: Int?
  if t.hasPrefix("0x") { value = Int(t.dropFirst(2), radix: 16) }
  else if t.hasPrefix("0b") { value = Int(t.dropFirst(2), radix: 2) }
  else { value = Int(t) }
  guard let v = value else { return nil }
  return negative ? -v : v
}

func parseLine(number: Int, raw: String, spec: CPUSpec) throws -> Line {
  var text = raw
  for marker in [";", "//"] {
    if let r = text.range(of: marker) { text = String(text[..<r.lowerBound]) }
  }
  text = text.trimmingCharacters(in: .whitespacesAndNewlines)
  
  var line = Line(number: number,
                  source: raw.trimmingCharacters(in: .whitespacesAndNewlines),
                  label: nil, op: nil, args: [])
  
  if let colon = text.firstIndex(of: ":") {
    let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
    guard isIdentifier(name) else {
      throw AsmError(line: number, message: "ラベル名が不正です: '\(name)'")
    }
    if spec.registerCodeByName[name.lowercased()] != nil
        || spec.instructionIndexByName[name.uppercased()] != nil
        || pseudoOps.contains(name.uppercased()) {
      throw AsmError(line: number, message: "'\(name)' は予約語なのでラベルに使えません")
    }
    line.label = name
    text = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
  }
  
  let tokens = text.replacingOccurrences(of: ",", with: " ")
    .split(whereSeparator: { $0 == " " || $0 == "\t" })
    .map(String.init)
  if let first = tokens.first {
    line.op = first.uppercased()
    line.args = Array(tokens.dropFirst())
  }
  return line
}

// MARK: - エンコード ---------------------------------------------------------

func encode(_ l: Line, labels: [String: Int], final: Bool, spec: CPUSpec) throws -> [UInt8] {
  guard let op = l.op else { return [] }
  
  func fail(_ m: String) -> AsmError { AsmError(line: l.number, message: m) }
  
  func value(_ s: String) throws -> Int {
    if let v = parseNumber(s) { return v }
    if let a = labels[s] { return a }
    if final { throw fail("未定義のラベルか不正な数値です: '\(s)'") }
    return 0   // 1パス目はサイズだけ分かればよい
  }
  func reg(_ s: String, bits: Int) throws -> Int {
    guard let r = spec.registerCodeByName[s.lowercased()] else {
      let names = spec.registers.map { $0.name }.joined(separator: ", ")
      throw fail("'\(s)' はレジスタではありません (\(names))")
    }
    guard r < (1 << bits) else {
      throw fail("レジスタ '\(s)' (コード \(r)) は \(bits) ビットのフィールドに入りません")
    }
    return r
  }
  func expect(_ count: Int) throws {
    if l.args.count != count {
      throw fail("\(op) のオペランドは \(count) 個必要です (\(l.args.count) 個指定)")
    }
  }
  func build(_ def: InstructionDef, imm: Int = 0, src: Int = 0, dst: Int = 0) -> UInt8 {
    let v = def.fixedValue
    | placeBits(imm, def.immBits)
    | placeBits(src, def.srcBits)
    | placeBits(dst, def.dstBits)
    return UInt8(truncatingIfNeeded: v)
  }
  // LI: set_bits 命令を並べて 8bit 即値をロードする
  func loadImm(_ v: Int) throws -> [UInt8] {
    guard !spec.liSteps.isEmpty else {
      throw fail("この CPU 定義では LI / ラベルジャンプは使えません (set_bits 命令で 8bit を埋められません)")
    }
    guard (0...255).contains(v) else { throw fail("\(v) は 8bit に収まりません") }
    return spec.liSteps.map { (step: LiStep) -> UInt8 in
      let width = step.hi - step.lo + 1
      let part = (v >> step.lo) & ((1 << width) - 1)
      return build(spec.instructions[step.instruction], imm: part)
    }
  }
  
  // --- ディレクティブ / 疑似命令 ---
  if op == ".BYTE" {
    guard !l.args.isEmpty else { throw fail(".byte には値が必要です") }
    return try l.args.map { (s: String) throws -> UInt8 in
      let v = try value(s)
      guard (-128...255).contains(v) else { throw fail("\(v) は 8bit に収まりません") }
      return UInt8(truncatingIfNeeded: v)
    }
  }
  if op == "LI" {
    try expect(1)
    return try loadImm(try value(l.args[0]))
  }
  
  guard let idx = spec.instructionIndexByName[op] else {
    throw fail("未知の命令です: '\(op)'")
  }
  let def = spec.instructions[idx]
  
  // ジャンプ命令にラベルや数値を渡した場合: LI → 即値用レジスタを経由 (そのレジスタは上書きされる)
  if case .jump = def.exec,
     def.operandOrder == [.src],
     l.args.count == 1,
     spec.registerCodeByName[l.args[0].lowercased()] == nil,
     let liReg = spec.liRegister {
    guard liReg < (1 << def.srcBits.count) else {
      throw fail("LI 用レジスタ (コード \(liReg)) が \(op) の S フィールドに入りません")
    }
    return try loadImm(try value(l.args[0])) + [build(def, src: liReg)]
  }
  
  // --- 通常命令 ---
  try expect(def.operandOrder.count)
  var imm = 0
  var src = 0
  var dst = 0
  for (k, kind) in def.operandOrder.enumerated() {
    let arg = l.args[k]
    switch kind {
    case .imm:
      let v = try value(arg)
      let maxV = (1 << def.immBits.count) - 1
      guard (0...maxV).contains(v) else {
        throw fail("\(op) の即値は 0〜\(maxV) です (\(v))")
      }
      imm = v
    case .src:
      src = try reg(arg, bits: def.srcBits.count)
    case .dst:
      dst = try reg(arg, bits: def.dstBits.count)
    }
  }
  return [build(def, imm: imm, src: src, dst: dst)]
}

func orgTarget(_ l: Line, pc: Int, spec: CPUSpec) throws -> Int {
  guard l.args.count == 1, let v = parseNumber(l.args[0]) else {
    throw AsmError(line: l.number, message: ".org にはアドレス(数値)を1つ指定してください")
  }
  guard (0...spec.programSize).contains(v) else {
    throw AsmError(line: l.number, message: ".org のアドレスが範囲外です: \(v)")
  }
  guard v >= pc else {
    throw AsmError(line: l.number, message: ".org で後ろへ戻ることはできません (現在 \(pc))")
  }
  return v
}

// MARK: - アセンブル (2パス) --------------------------------------------------

func assemble(_ text: String, spec: CPUSpec) -> AssemblyResult {
  var result = AssemblyResult()
  var lines: [Line] = []
  
  // CRLF / CR を LF にそろえる (行番号がずれないように)
  let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
    .replacingOccurrences(of: "\r", with: "\n")
  for (i, raw) in normalized.components(separatedBy: "\n").enumerated() {
    do { lines.append(try parseLine(number: i + 1, raw: raw, spec: spec)) }
    catch let e as AsmError { result.errors.append(e) }
    catch {}
  }
  
  // 1パス目: ラベルのアドレスを確定
  var labels: [String: Int] = [:]
  var pc = 0
  for l in lines {
    if let name = l.label {
      if labels[name] != nil {
        result.errors.append(AsmError(line: l.number, message: "ラベル '\(name)' が重複しています"))
      } else {
        labels[name] = pc
      }
    }
    guard let op = l.op else { continue }
    if op == ".ORG" {
      if let t = try? orgTarget(l, pc: pc, spec: spec) { pc = t }
    } else if let out = try? encode(l, labels: labels, final: false, spec: spec) {
      pc += out.count
    }
  }
  
  // 2パス目: 機械語を生成
  for l in lines {
    guard let op = l.op else { continue }
    do {
      if op == ".ORG" {
        let target = try orgTarget(l, pc: result.bytes.count, spec: spec)
        while result.bytes.count < target { result.bytes.append(0) }
        continue
      }
      let out = try encode(l, labels: labels, final: true, spec: spec)
      for (i, b) in out.enumerated() {
        result.rows.append(ListingRow(addr: result.bytes.count,
                                      byte: b,
                                      source: i == 0 ? l.source : nil,
                                      line: l.number))
        result.bytes.append(b)
      }
      if result.bytes.count > spec.programSize {
        throw AsmError(line: l.number, message: "プログラムが \(spec.programSize) バイトを超えました")
      }
    } catch let e as AsmError {
      result.errors.append(e)
    } catch {}
  }
  result.errors.sort { $0.line < $1.line }
  return result
}

// MARK: - 出力 ---------------------------------------------------------------

func hex2(_ v: Int) -> String {
  let s = String(v, radix: 16, uppercase: true)
  return s.count < 2 ? "0" + s : s
}

func bin4(_ v: Int) -> String {
  let s = String(v, radix: 2)
  return String(repeating: "0", count: max(0, 4 - s.count)) + s
}

func formatOutput(_ bytes: [UInt8], format: OutputFormat) -> Data {
  switch format {
  case .hex:      // 1行1バイト ($readmemh 用)
    return Data((bytes.map { hex2(Int($0)) }.joined(separator: "\n") + "\n").utf8)
  case .logisim:  // Logisim "v2.0 raw"
    var out = "v2.0 raw\n"
    for start in stride(from: 0, to: bytes.count, by: 16) {
      let chunk = bytes[start..<min(start + 16, bytes.count)]
      out += chunk.map { hex2(Int($0)).lowercased() }.joined(separator: " ") + "\n"
    }
    return Data(out.utf8)
  case .bin:      // 生バイナリ
    return Data(bytes)
  }
}
