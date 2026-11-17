import Foundation

// MARK: - エミュレータ -------------------------------------------------------
//
// 命令の動作・レジスタ・メモリサイズ・フラグの規則はすべて CPUSpec (CPU 定義ファイル) で決まる。
// 定義ファイルで表せない部分の仮定:
//  - 命令メモリ(ROM)とデータ RAM は別。sharedMemory = true なら RAM 上にプログラムを置く
//  - set_bits / load / move / store / jump 系はフラグを変えない (ALU 命令だけが carry / zero を更新)
//  - 8bit データ、PC も 8bit

struct CPUStateKey: Hashable {
  let pc: UInt8
  let reg: [UInt8]
  let carry: Bool
  let zero: Bool
  let ram: [UInt8]
}

struct Emulator {
  static let maxSteps = 100_000
  private static let seenLimit = 20_000
  
  let spec: CPUSpec
  let rom: [UInt8]
  let shared: Bool
  
  var pc: UInt8 = 0
  var reg: [UInt8]
  var carry = false
  var zero = false
  var ram: [UInt8]
  var steps = 0
  var haltReason: String? = nil
  private var seen = Set<CPUStateKey>()    // 無限ループ(停止)検出用
  
  init(program: [UInt8], shared: Bool, spec: CPUSpec) {
    self.spec = spec
    self.rom = program
    self.shared = shared
    self.reg = [UInt8](repeating: 0, count: spec.regSlots)
    self.ram = [UInt8](repeating: 0, count: spec.ramSize)
    if shared {
      for (i, b) in program.prefix(spec.ramSize).enumerated() { ram[i] = b }
    }
  }
  
  // MARK: レジスタ・メモリ
  
  func read(_ code: Int) -> UInt8 {
    (code >= 0 && code < reg.count) ? reg[code] : 0
  }
  
  private mutating func write(_ code: Int, _ value: UInt8) {
    if code >= 0 && code < reg.count { reg[code] = value }
  }
  
  private func ramIndex(_ v: UInt8) -> Int {
    Int(v) % spec.ramSize
  }
  
  private var accCode: Int { spec.accumulator ?? 0 }
  private var addrCode: Int { spec.addressRegister ?? 0 }
  
  /// PC が指す命令バイト (ROM の範囲外なら nil)
  var currentByte: UInt8? {
    let i = Int(pc)
    if shared { return ram[i % spec.ramSize] }
    return i < rom.count ? rom[i] : nil
  }
  
  // MARK: 実行
  
  mutating func step() {
    guard haltReason == nil else { return }
    guard let code = currentByte else {
      haltReason = "プログラム終端 (アドレス \(hex2(Int(pc)))) に到達しました"
      return
    }
    guard let def = spec.decode(code) else {
      haltReason = "未定義の命令 \(hex2(Int(code))) (アドレス \(hex2(Int(pc))))"
      return
    }
    
    let imm = extractBits(code, def.immBits)
    let s = extractBits(code, def.srcBits)
    let d = extractBits(code, def.dstBits)
    var next = pc &+ 1
    var jumped = false
    
    switch def.exec {
    case .setBits(let r, let lo, let hi):
      let mask = ((1 << (hi - lo + 1)) - 1) << lo
      let old = Int(read(r))
      write(r, UInt8(truncatingIfNeeded: (old & ~mask) | ((imm << lo) & mask)))
    case .load:
      write(d, ram[ramIndex(read(addrCode))])
    case .store:
      ram[ramIndex(read(addrCode))] = read(s)
    case .jump(let cond):
      let take: Bool
      switch cond {
      case .always:   take = true
      case .carry:    take = carry
      case .notCarry: take = !carry
      case .zero:     take = zero
      case .notZero:  take = !zero
      }
      if take {
        next = read(s)
        jumped = true
      }
    case .move:
      write(d, read(s))
    case .alu(let op):
      alu(op, operand: op.needsSource ? Int(read(s)) : 0)
    case .nop:
      break
    case .halt:
      haltReason = "HALT 命令で停止しました"
    }
    
    pc = next
    steps += 1
    if jumped { detectLoop() }
  }
  
  private mutating func alu(_ op: AluOp, operand b: Int) {
    let a = Int(read(accCode))
    var r = 0
    var newCarry = carry
    let logicCarry = spec.logicClearsCarry ? false : carry
    
    switch op {
    case .not: r = ~a & 0xFF; newCarry = logicCarry
    case .and: r = a & b;     newCarry = logicCarry
    case .or:  r = a | b;     newCarry = logicCarry
    case .xor: r = a ^ b;     newCarry = logicCarry
    case .add: r = a + b;     newCarry = r > 0xFF
    case .inc: r = a + 1;     newCarry = r > 0xFF
    case .sub: r = a - b;     newCarry = spec.subCarryInverted ? !(r < 0) : (r < 0)
    case .dec: r = a - 1;     newCarry = spec.subCarryInverted ? !(r < 0) : (r < 0)
    }
    
    write(accCode, UInt8(truncatingIfNeeded: r))
    carry = newCarry
    zero = read(accCode) == 0
  }
  
  /// ジャンプ後に「完全に同じ状態」へ戻ったら、以後は永久に同じ動作なので停止とみなす
  private mutating func detectLoop() {
    guard seen.count < Emulator.seenLimit else { return }
    let key = CPUStateKey(pc: pc, reg: reg, carry: carry, zero: zero, ram: ram)
    if !seen.insert(key).inserted {
      haltReason = "同じ状態に戻りました (停止 / 無限ループ)  PC=\(hex2(Int(pc)))"
    }
  }
  
  mutating func run(limit: Int = Emulator.maxSteps) {
    var n = 0
    while haltReason == nil && n < limit {
      step()
      n += 1
    }
    if haltReason == nil {
      haltReason = "ステップ上限 (\(limit)) に到達しました"
    }
  }
}

// MARK: - 逆アセンブラ -------------------------------------------------------

struct DisasmRow: Identifiable {
  let addr: Int
  let byte: UInt8
  let text: String
  let stray: Bool          // 未使用ビット(X)が 0 でない
  var id: Int { addr }
}

enum Disassembler {
  static func describe(_ byte: UInt8, spec: CPUSpec) -> (text: String, stray: Bool) {
    guard let def = spec.decode(byte) else { return ("???", false) }
    
    var parts: [String] = []
    for kind in def.operandOrder {
      switch kind {
      case .imm:
        let v = extractBits(byte, def.immBits)
        parts.append(v < 10 ? String(v) : "0x" + String(v, radix: 16, uppercase: true))
      case .src:
        parts.append(spec.registerName(extractBits(byte, def.srcBits)))
      case .dst:
        parts.append(spec.registerName(extractBits(byte, def.dstBits)))
      }
    }
    let text = parts.isEmpty ? def.name : def.name + " " + parts.joined(separator: ", ")
    return (text, (Int(byte) & def.unusedMask) != 0)
  }
  
  static func text(for byte: UInt8, spec: CPUSpec) -> String {
    describe(byte, spec: spec).text
  }
  
  static func disassemble(_ bytes: [UInt8], spec: CPUSpec) -> [DisasmRow] {
    bytes.enumerated().map { (i, b) in
      let d = describe(b, spec: spec)
      return DisasmRow(addr: i, byte: b, text: d.text, stray: d.stray)
    }
  }
  
  /// ファイルからバイト列を取り出す。
  /// .bin は生バイナリ、それ以外は 16進テキスト (1行1バイト / Logisim v2.0 raw) を試し、
  /// 解釈できなければ生バイナリとして扱う。
  static func parseFile(data: Data, fileExtension: String) -> [UInt8] {
    if fileExtension.lowercased() != "bin",
       let text = String(data: data, encoding: .utf8),
       let bytes = parseHexText(text) {
      return bytes
    }
    return [UInt8](data)
  }
  
  static func parseHexText(_ text: String) -> [UInt8]? {
    var out: [UInt8] = []
    for rawLine in text.components(separatedBy: "\n") {
      var line = rawLine
      for marker in ["#", "//"] {
        if let r = line.range(of: marker) { line = String(line[..<r.lowerBound]) }
      }
      let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "," || $0 == "\r" })
      for token in tokens {
        var t = token.lowercased()
        if t == "v2.0" || t == "raw" { continue }
        if t.hasPrefix("0x") { t = String(t.dropFirst(2)) }
        // Logisim の連続表記 "N*xx"
        if let star = t.firstIndex(of: "*") {
          guard let count = Int(t[..<star]),
                let v = UInt8(t[t.index(after: star)...], radix: 16) else { return nil }
          out += [UInt8](repeating: v, count: count)
          continue
        }
        guard let v = UInt8(t, radix: 16) else { return nil }
        out.append(v)
      }
    }
    return out.isEmpty ? nil : out
  }
}
