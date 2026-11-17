import Foundation

// MARK: - 定義ファイル (JSON) の形 ---------------------------------------------------

struct CPUFile: Decodable {
  var name: String?
  var programSize: Int?
  var ramSize: Int?
  var sharedMemory: Bool?
  var registers: [String: Int]
  var accumulator: String?
  var addressRegister: String?
  var flags: FlagsFile?
  var instructions: [InstructionFile]
  
  struct FlagsFile: Decodable {
    var subCarry: String?
    var logicClearsCarry: Bool?
  }
  
  struct InstructionFile: Decodable {
    var name: String
    var pattern: String
    var exec: String
    var reg: String?
    var bits: [Int]?
    var operands: [String]?
    var summary: String?
    var color: String?
  }
}

struct SpecError: Error {
  let message: String
}

// MARK: - コンパイル済みの CPU 仕様 ---------------------------------------------------

enum OperandKind: Hashable { case dst, src, imm }

enum JumpCondition { case always, carry, notCarry, zero, notZero }

enum AluOp {
  case not, and, or, xor, add, sub, inc, dec
  var needsSource: Bool {
    switch self {
    case .not, .inc, .dec: return false
    default: return true
    }
  }
}

enum Exec {
  case setBits(reg: Int, lo: Int, hi: Int)   // imm -> reg[hi:lo]
  case load                                   // RAM[addressRegister] -> D
  case store                                  // S -> RAM[addressRegister]
  case jump(JumpCondition)                    // S -> PC
  case move                                   // S -> D
  case alu(AluOp)                             // ACC (op S) -> ACC
  case nop
  case halt
}

struct RegisterDef {
  let name: String
  let code: Int
}

/// LI 疑似命令を構成する 1 ステップ (set_bits 命令 1 つ分)
struct LiStep {
  let instruction: Int    // spec.instructions のインデックス
  let lo: Int
  let hi: Int
}

/// bit 位置 (7 = MSB) のリストを MSB 側から順に並べて値を取り出す
func extractBits(_ byte: UInt8, _ bits: [Int]) -> Int {
  var v = 0
  for b in bits {
    v = (v << 1) | Int((byte >> UInt8(b)) & 1)
  }
  return v
}

/// 値を bit 位置リスト (MSB 側から) に配置する
func placeBits(_ value: Int, _ bits: [Int]) -> Int {
  var r = 0
  let n = bits.count
  for (k, b) in bits.enumerated() {
    r |= ((value >> (n - 1 - k)) & 1) << b
  }
  return r
}

struct InstructionDef {
  let name: String
  let pattern: String        // 8 文字 (空白なし・小文字)
  let fixedMask: Int         // 0/1 で固定されているビット
  let fixedValue: Int
  let unusedMask: Int        // X / . のビット
  let immBits: [Int]
  let srcBits: [Int]
  let dstBits: [Int]
  let operandOrder: [OperandKind]
  let exec: Exec
  let summary: String
  let colorName: String
  
  var syntax: String {
    let parts = operandOrder.map { (kind: OperandKind) -> String in
      switch kind {
      case .dst: return "d"
      case .src: return "s"
      case .imm: return "imm\(immBits.count)"
      }
    }
    return parts.isEmpty ? name : name + " " + parts.joined(separator: ", ")
  }
  
  /// 表示用: "0010 ..DD"
  var spacedPattern: String {
    let up = pattern.uppercased()
    return String(up.prefix(4)) + " " + String(up.dropFirst(4))
  }
}

struct CPUSpec {
  let name: String
  let programSize: Int
  let ramSize: Int
  let sharedMemoryDefault: Bool
  let registers: [RegisterDef]            // コード順
  let accumulator: Int?
  let addressRegister: Int?
  let subCarryInverted: Bool
  let logicClearsCarry: Bool
  let instructions: [InstructionDef]
  let registerCodeByName: [String: Int]   // キーは小文字
  let instructionIndexByName: [String: Int]   // キーは大文字
  let liRegister: Int?
  let liSteps: [LiStep]
  let regSlots: Int
  
  /// 機械語 1 バイトに一致する命令定義
  func decode(_ byte: UInt8) -> InstructionDef? {
    let b = Int(byte)
    return instructions.first { (b & $0.fixedMask) == $0.fixedValue }
  }
  
  func registerName(_ code: Int) -> String {
    registers.first { $0.code == code }?.name ?? "?\(code)"
  }
  
  /// シンタックスハイライトのキャッシュ判定用
  var highlightKey: String {
    instructions.map { $0.name }.joined(separator: ",")
    + "|" + registers.map { $0.name }.joined(separator: ",")
    + (liSteps.isEmpty ? "" : "|li")
  }
  
  /// 定義が 1 つも読めなかったときの最小仕様
  static let empty = CPUSpec(name: "(定義なし)", programSize: 256, ramSize: 256,
                             sharedMemoryDefault: false, registers: [],
                             accumulator: nil, addressRegister: nil,
                             subCarryInverted: false, logicClearsCarry: true,
                             instructions: [], registerCodeByName: [:],
                             instructionIndexByName: [:], liRegister: nil,
                             liSteps: [], regSlots: 1)
  
  static var defaultJSON: String { cpuDefaultJSON }
  
  /// 内蔵の標準定義。失敗してもアプリは起動できるよう、空の仕様とエラー文を返す
  static func builtin() -> (spec: CPUSpec, error: String?) {
    do {
      return (try parse(json: cpuDefaultJSON), nil)
    } catch let e as SpecError {
      return (empty, "内蔵 CPU 定義の読み込みに失敗: \(e.message)")
    } catch {
      return (empty, "内蔵 CPU 定義の読み込みに失敗しました")
    }
  }
}

// MARK: - 読み込みと検証 -------------------------------------------------------------

extension CPUSpec {
  
  static func parse(json: String) throws -> CPUSpec {
    guard let data = json.data(using: .utf8) else {
      throw SpecError(message: "文字コードを読み取れません")
    }
    let file: CPUFile
    do {
      file = try JSONDecoder().decode(CPUFile.self, from: data)
    } catch let e as DecodingError {
      throw SpecError(message: describe(e))
    } catch {
      throw SpecError(message: "JSON を読み取れません: \(error.localizedDescription)")
    }
    return try compile(file)
  }
  
  private static func describe(_ e: DecodingError) -> String {
    func path(_ keys: [CodingKey]) -> String {
      if keys.isEmpty { return "ルート" }
      var s = ""
      for k in keys {
        if let i = k.intValue { s += "[\(i)]" } else { s += "." + k.stringValue }
      }
      return s
    }
    switch e {
    case .keyNotFound(let key, let ctx):
      return "項目 '\(key.stringValue)' がありません (場所: \(path(ctx.codingPath)))"
    case .typeMismatch(_, let ctx):
      return "値の型が違います (場所: \(path(ctx.codingPath)))"
    case .valueNotFound(_, let ctx):
      return "値がありません (場所: \(path(ctx.codingPath)))"
    case .dataCorrupted(let ctx):
      var detail = ctx.debugDescription
      if let under = ctx.underlyingError as NSError?,
         let d = under.userInfo[NSDebugDescriptionErrorKey] as? String {
        detail = d
      }
      return "JSON の書式エラー: \(detail)"
    @unknown default:
      return e.localizedDescription
    }
  }
  
  static func compile(_ f: CPUFile) throws -> CPUSpec {
    func fail(_ m: String) -> SpecError { SpecError(message: m) }
    
    // --- サイズ ---
    let programSize = f.programSize ?? 256
    let ramSize = f.ramSize ?? 256
    guard (1...256).contains(programSize) else { throw fail("programSize は 1〜256 にしてください") }
    guard (1...256).contains(ramSize) else { throw fail("ramSize は 1〜256 にしてください") }
    
    // --- レジスタ ---
    guard !f.registers.isEmpty else { throw fail("registers が空です") }
    var regs: [RegisterDef] = []
    var nameToCode: [String: Int] = [:]
    var codeToName: [Int: String] = [:]
    let sortedRegs = f.registers.sorted { a, b in
      a.value != b.value ? a.value < b.value : a.key < b.key
    }
    for (rawName, code) in sortedRegs {
      let name = rawName.lowercased()
      guard isIdentifier(name) else { throw fail("レジスタ名が不正です: '\(rawName)'") }
      guard (0...255).contains(code) else { throw fail("レジスタ '\(rawName)' のコードは 0〜255 にしてください") }
      if let other = codeToName[code] {
        throw fail("レジスタ '\(rawName)' と '\(other)' のコード \(code) が重複しています")
      }
      guard nameToCode[name] == nil else { throw fail("レジスタ名が重複しています: '\(name)'") }
      nameToCode[name] = code
      codeToName[code] = name
      regs.append(RegisterDef(name: name, code: code))
    }
    let codeByName = nameToCode
    
    func regCode(_ n: String?, _ what: String) throws -> Int? {
      guard let n = n else { return nil }
      guard let c = codeByName[n.lowercased()] else {
        throw fail("\(what) '\(n)' は registers にありません")
      }
      return c
    }
    let accumulator = try regCode(f.accumulator, "accumulator")
    let addressRegister = try regCode(f.addressRegister, "addressRegister")
    
    func regLabel(_ c: Int?) -> String {
      guard let c = c else { return "?" }
      return (codeToName[c] ?? "?").uppercased()
    }
    
    func autoSummary(_ exec: Exec) -> String {
      switch exec {
      case .setBits(let r, let lo, let hi): return "imm → \(regLabel(r))[\(hi):\(lo)]"
      case .load:  return "RAM[\(regLabel(addressRegister))] → d"
      case .store: return "s → RAM[\(regLabel(addressRegister))]"
      case .jump(let c):
        switch c {
        case .always:   return "s → PC"
        case .carry:    return "carry = 1 のとき s → PC"
        case .notCarry: return "carry = 0 のとき s → PC"
        case .zero:     return "zero = 1 のとき s → PC"
        case .notZero:  return "zero = 0 のとき s → PC"
        }
      case .move: return "s → d"
      case .alu(let op):
        let a = regLabel(accumulator)
        switch op {
        case .not: return "~\(a) → \(a)"
        case .and: return "\(a) & s → \(a)"
        case .or:  return "\(a) | s → \(a)"
        case .xor: return "\(a) ^ s → \(a)"
        case .add: return "\(a) + s → \(a)"
        case .sub: return "\(a) - s → \(a)"
        case .inc: return "\(a) + 1 → \(a)"
        case .dec: return "\(a) - 1 → \(a)"
        }
      case .nop:  return "何もしない"
      case .halt: return "停止"
      }
    }
    
    // --- 命令 ---
    guard !f.instructions.isEmpty else { throw fail("instructions が空です") }
    var defs: [InstructionDef] = []
    var seenNames = Set<String>()
    
    for (n, inst) in f.instructions.enumerated() {
      let label = "instructions[\(n)] (\(inst.name))"
      let name = inst.name.uppercased()
      
      guard isIdentifier(name) else { throw fail("\(label): 命令名が不正です") }
      guard name != "LI" else { throw fail("\(label): 'LI' は疑似命令の名前なので使えません") }
      guard codeByName[name.lowercased()] == nil else {
        throw fail("\(label): レジスタと同じ名前は使えません")
      }
      guard seenNames.insert(name).inserted else { throw fail("\(label): 命令名が重複しています") }
      
      // pattern
      let pattern = inst.pattern.filter { $0 != " " && $0 != "_" }.lowercased()
      guard pattern.count == 8 else {
        throw fail("\(label): pattern は 8 文字にしてください (現在 \(pattern.count) 文字)")
      }
      var fixedMask = 0
      var fixedValue = 0
      var unused = 0
      var imm: [Int] = []
      var src: [Int] = []
      var dst: [Int] = []
      for (j, ch) in pattern.enumerated() {
        let bit = 7 - j
        switch ch {
        case "0": fixedMask |= 1 << bit
        case "1": fixedMask |= 1 << bit; fixedValue |= 1 << bit
        case "i": imm.append(bit)
        case "s": src.append(bit)
        case "d": dst.append(bit)
        case "x", ".": unused |= 1 << bit
        default:
          throw fail("\(label): pattern に使えない文字 '\(ch)' があります (使えるのは 0 1 i S D X .)")
        }
      }
      
      func need(_ ok: Bool, _ what: String) throws {
        if !ok { throw fail("\(label): exec '\(inst.exec)' には \(what) が必要です") }
      }
      
      // exec
      let exec: Exec
      switch inst.exec.lowercased() {
      case "set_bits":
        guard let rn = inst.reg, let rc = codeByName[rn.lowercased()] else {
          throw fail("\(label): set_bits には reg (registers にある名前) が必要です")
        }
        guard let b = inst.bits, b.count == 2, b[0] >= 0, b[1] <= 7, b[0] <= b[1] else {
          throw fail("\(label): bits は [下位bit, 上位bit] (例 [0, 3]) で指定してください")
        }
        guard imm.count == b[1] - b[0] + 1 else {
          throw fail("\(label): pattern の i の数 (\(imm.count)) と bits の幅 (\(b[1] - b[0] + 1)) が一致しません")
        }
        exec = .setBits(reg: rc, lo: b[0], hi: b[1])
      case "load":
        try need(!dst.isEmpty, "D ビット")
        try need(addressRegister != nil, "addressRegister の指定")
        exec = .load
      case "store":
        try need(!src.isEmpty, "S ビット")
        try need(addressRegister != nil, "addressRegister の指定")
        exec = .store
      case "jump", "jump_if_carry", "jump_if_not_carry", "jump_if_zero", "jump_if_not_zero":
        try need(!src.isEmpty, "S ビット")
        switch inst.exec.lowercased() {
        case "jump_if_carry":     exec = .jump(.carry)
        case "jump_if_not_carry": exec = .jump(.notCarry)
        case "jump_if_zero":      exec = .jump(.zero)
        case "jump_if_not_zero":  exec = .jump(.notZero)
        default:                  exec = .jump(.always)
        }
      case "move":
        try need(!src.isEmpty && !dst.isEmpty, "S ビットと D ビット")
        exec = .move
      case "and", "or", "xor", "add", "sub":
        try need(!src.isEmpty, "S ビット")
        try need(accumulator != nil, "accumulator の指定")
        switch inst.exec.lowercased() {
        case "and": exec = .alu(.and)
        case "or":  exec = .alu(.or)
        case "xor": exec = .alu(.xor)
        case "add": exec = .alu(.add)
        default:    exec = .alu(.sub)
        }
      case "not", "inc", "dec":
        try need(accumulator != nil, "accumulator の指定")
        switch inst.exec.lowercased() {
        case "not": exec = .alu(.not)
        case "inc": exec = .alu(.inc)
        default:    exec = .alu(.dec)
        }
      case "nop":  exec = .nop
      case "halt": exec = .halt
      default:
        throw fail("\(label): 未知の exec '\(inst.exec)' (set_bits / load / store / jump / jump_if_carry / jump_if_not_carry / jump_if_zero / jump_if_not_zero / move / not / and / or / xor / add / sub / inc / dec / nop / halt)")
      }
      
      // アセンブリ上のオペランド順 (既定は D, S, I)
      var present: [OperandKind] = []
      if !dst.isEmpty { present.append(.dst) }
      if !src.isEmpty { present.append(.src) }
      if !imm.isEmpty { present.append(.imm) }
      var order = present
      if let ops = inst.operands {
        var custom: [OperandKind] = []
        for o in ops {
          switch o.lowercased() {
          case "d": custom.append(.dst)
          case "s": custom.append(.src)
          case "i", "imm": custom.append(.imm)
          default: throw fail("\(label): operands に使えるのは \"D\" \"S\" \"I\" です ('\(o)')")
          }
        }
        guard custom.count == present.count, Set(custom) == Set(present) else {
          throw fail("\(label): operands は pattern にあるフィールド (D / S / I) を 1 回ずつ並べてください")
        }
        order = custom
      }
      
      defs.append(InstructionDef(
        name: name, pattern: pattern,
        fixedMask: fixedMask, fixedValue: fixedValue, unusedMask: unused,
        immBits: imm, srcBits: src, dstBits: dst,
        operandOrder: order, exec: exec,
        summary: inst.summary ?? autoSummary(exec),
        colorName: inst.color ?? "gray"))
    }
    
    // --- opcode の重複チェック ---
    for i in 0..<defs.count {
      for j in (i + 1)..<defs.count {
        let common = defs[i].fixedMask & defs[j].fixedMask
        if (defs[i].fixedValue ^ defs[j].fixedValue) & common == 0 {
          throw fail("\(defs[i].name) と \(defs[j].name) の pattern が重複しています (同じ機械語が両方に一致します)")
        }
      }
    }
    
    // --- LI (set_bits 命令で 8bit を過不足なく埋められるときだけ有効) ---
    var liSteps: [LiStep] = []
    var liReg: Int? = nil
    for (idx, d) in defs.enumerated() {
      if case .setBits(let r, let lo, let hi) = d.exec {
        if liReg == nil { liReg = r }
        if r == liReg { liSteps.append(LiStep(instruction: idx, lo: lo, hi: hi)) }
      }
    }
    var coverage = 0
    var total = 0
    for s in liSteps {
      for b in s.lo...s.hi { coverage |= 1 << b }
      total += s.hi - s.lo + 1
    }
    if coverage != 0xFF || total != 8 {
      liSteps = []
      liReg = nil
    }
    
    // --- フラグ ---
    let sub = (f.flags?.subCarry ?? "borrow").lowercased()
    guard sub == "borrow" || sub == "inverted" else {
      throw fail("flags.subCarry は \"borrow\" か \"inverted\" にしてください")
    }
    
    var byName: [String: Int] = [:]
    for (i, d) in defs.enumerated() { byName[d.name] = i }
    let maxCode = regs.map { $0.code }.max() ?? 0
    
    return CPUSpec(name: f.name ?? "名称未設定の CPU",
                   programSize: programSize,
                   ramSize: ramSize,
                   sharedMemoryDefault: f.sharedMemory ?? false,
                   registers: regs,
                   accumulator: accumulator,
                   addressRegister: addressRegister,
                   subCarryInverted: sub == "inverted",
                   logicClearsCarry: f.flags?.logicClearsCarry ?? true,
                   instructions: defs,
                   registerCodeByName: codeByName,
                   instructionIndexByName: byName,
                   liRegister: liReg,
                   liSteps: liSteps,
                   regSlots: maxCode + 1)
  }
}

// MARK: - 内蔵の標準 CPU 定義 (cpu_default.json と同じ内容) ---------------------------

let cpuDefaultJSON = """
{
  "name": "8bit CPU (標準)",
  "programSize": 256,
  "ramSize": 256,
  "sharedMemory": false,
  "registers": { "r0": 0, "r1": 1, "acc": 2, "mar": 3 },
  "accumulator": "acc",
  "addressRegister": "mar",
  "flags": { "subCarry": "borrow", "logicClearsCarry": true },
  "instructions": [
    { "name": "LUI", "pattern": "0000iiii", "exec": "set_bits", "reg": "r0", "bits": [0, 3], "summary": "imm → R0[3:0]", "color": "red" },
    { "name": "LLI", "pattern": "0001iiii", "exec": "set_bits", "reg": "r0", "bits": [4, 7], "summary": "imm → R0[7:4]", "color": "red" },
    { "name": "LD",  "pattern": "0010..DD", "exec": "load",  "summary": "RAM[MAR] → d", "color": "orange" },
    { "name": "STR", "pattern": "0011SS..", "exec": "store", "summary": "s → RAM[MAR]", "color": "orange" },
    { "name": "JMP", "pattern": "0100SS..", "exec": "jump", "summary": "s → PC", "color": "teal" },
    { "name": "JC",  "pattern": "0101SS..", "exec": "jump_if_carry", "summary": "carry = 1 のとき s → PC", "color": "teal" },
    { "name": "JZ",  "pattern": "0110SS..", "exec": "jump_if_zero", "summary": "zero = 1 のとき s → PC", "color": "teal" },
    { "name": "MOV", "pattern": "0111SSDD", "exec": "move", "operands": ["D", "S"], "summary": "s → d  (書式: MOV d, s)", "color": "green" },
    { "name": "NOT", "pattern": "1000....", "exec": "not", "summary": "~ACC → ACC", "color": "blue" },
    { "name": "AND", "pattern": "1001SS..", "exec": "and", "summary": "ACC & s → ACC", "color": "blue" },
    { "name": "OR",  "pattern": "1010SS..", "exec": "or",  "summary": "ACC | s → ACC", "color": "blue" },
    { "name": "XOR", "pattern": "1011SS..", "exec": "xor", "summary": "ACC ^ s → ACC", "color": "blue" },
    { "name": "ADD", "pattern": "1100SS..", "exec": "add", "summary": "ACC + s → ACC", "color": "blue" },
    { "name": "SUB", "pattern": "1101SS..", "exec": "sub", "summary": "ACC - s → ACC", "color": "blue" },
    { "name": "INC", "pattern": "1110....", "exec": "inc", "summary": "ACC + 1 → ACC", "color": "blue" },
    { "name": "DEC", "pattern": "1111....", "exec": "dec", "summary": "ACC - 1 → ACC", "color": "blue" }
  ]
}
"""
