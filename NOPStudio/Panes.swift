import SwiftUI

private let mono = Font.system(.body, design: .monospaced)
private let monoSmall = Font.system(.caption, design: .monospaced)

/// CPU 定義の "color" 文字列 → 色
func specColor(_ name: String) -> Color {
  switch name.lowercased() {
  case "red":              return .red
  case "orange", "yellow": return .orange
  case "teal", "cyan":     return .teal
  case "green":            return .green
  case "blue":             return .blue
  case "purple":           return .purple
  case "pink":             return .pink
  default:                 return .gray
  }
}

// MARK: - アセンブルリスト ---------------------------------------------------------

struct ListingPane: View {
  @ObservedObject var model: AssemblerModel
  
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Text("addr").frame(width: 40, alignment: .leading)
        Text("hex").frame(width: 36, alignment: .leading)
        Text("上位  下位").frame(width: 110, alignment: .leading)
        Text("source")
        Spacer()
      }
      .font(monoSmall)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      
      Divider()
      
      List(model.result.rows) { row in
        let v = Int(row.byte)
        HStack(spacing: 12) {
          Text(hex2(row.addr)).frame(width: 40, alignment: .leading)
          Text(hex2(v)).frame(width: 36, alignment: .leading)
          Text("\(bin4(v >> 4))  \(bin4(v & 0xF))").frame(width: 110, alignment: .leading)
          Text(row.source ?? "").foregroundStyle(.secondary)
        }
        .font(mono)
      }
    }
  }
}

// MARK: - 逆アセンブル -------------------------------------------------------------

struct DisassemblyPane: View {
  @ObservedObject var model: AssemblerModel
  
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(model.disasmTitle.isEmpty
             ? "バイナリを開くか、現在のアセンブル結果を表示してください"
             : model.disasmTitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        Spacer()
        Button("現在の結果") { model.showCurrentDisassembly() }
          .disabled(!model.canRun)
        Button("バイナリを開く…") { model.openBinaryForDisassembly() }
      }
      .padding(8)
      
      Divider()
      
      List(model.disasmRows) { row in
        let v = Int(row.byte)
        HStack(spacing: 12) {
          Text(hex2(row.addr)).frame(width: 40, alignment: .leading)
          Text(hex2(v)).frame(width: 36, alignment: .leading)
          Text("\(bin4(v >> 4))  \(bin4(v & 0xF))").frame(width: 110, alignment: .leading)
          Text(row.text)
          if row.stray {
            Text("未使用ビット ≠ 0")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          Spacer()
        }
        .font(mono)
      }
    }
  }
}

// MARK: - エミュレータ -------------------------------------------------------------

struct EmulatorPane: View {
  @ObservedObject var model: AssemblerModel
  
  var body: some View {
    let cpu = model.cpu
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if !model.canRun {
          Label("エラーがあるため実行できません", systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
        
        nextInstruction(cpu)
        
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)],
                  alignment: .leading, spacing: 8) {
          regCard("PC", cpu.pc)
          ForEach(model.spec.registers, id: \.name) { r in
            regCard(r.name.uppercased(), cpu.read(r.code))
          }
        }
        
        HStack(spacing: 8) {
          flagBadge("C", cpu.carry)
          flagBadge("Z", cpu.zero)
          Spacer()
        }
        
        Toggle("プログラムを RAM 上に置く (命令とデータで同じメモリ)", isOn: $model.sharedMemory)
          .font(.callout)
        
        VStack(alignment: .leading, spacing: 6) {
          Text("RAM (\(cpu.spec.ramSize) バイト)")
            .font(.headline)
          ramGrid(cpu)
        }
      }
      .padding(12)
    }
  }
  
  private func nextInstruction(_ cpu: Emulator) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let reason = cpu.haltReason {
        Label(reason, systemImage: "stop.circle.fill")
          .foregroundStyle(.orange)
      } else if let byte = cpu.currentByte {
        HStack(spacing: 8) {
          Text("次の命令").foregroundStyle(.secondary)
          Text("\(hex2(Int(cpu.pc))): \(hex2(Int(byte)))   \(Disassembler.text(for: byte, spec: cpu.spec))")
            .font(mono)
        }
      }
      Text("実行ステップ数: \(cpu.steps)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
  
  private func regCard(_ name: String, _ value: UInt8) -> some View {
    VStack(spacing: 2) {
      Text(name)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(hex2(Int(value)))
        .font(.system(.title2, design: .monospaced))
        .bold()
      Text("\(value)")
        .font(monoSmall)
        .foregroundStyle(.secondary)
    }
    .frame(minWidth: 52)
    .padding(.vertical, 8)
    .padding(.horizontal, 6)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
  }
  
  private func flagBadge(_ name: String, _ on: Bool) -> some View {
    Text(name)
      .font(.system(.title3, design: .monospaced))
      .bold()
      .frame(width: 36, height: 36)
      .foregroundStyle(on ? Color.white : Color.secondary)
      .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
  }
  
  private func ramGrid(_ cpu: Emulator) -> some View {
    let rows = (cpu.spec.ramSize + 15) / 16
    let addrReg = cpu.spec.addressRegister
    let marAddr: Int? = addrReg.map { Int(cpu.read($0)) % cpu.spec.ramSize }
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 4) {
        Text("").frame(width: 24)
        ForEach(0..<16, id: \.self) { c in
          Text(String(c, radix: 16, uppercase: true))
            .frame(width: 24)
            .foregroundStyle(.secondary)
        }
      }
      ForEach(0..<rows, id: \.self) { r in
        HStack(spacing: 4) {
          Text(hex2(r * 16))
            .frame(width: 24, alignment: .trailing)
            .foregroundStyle(.secondary)
          ForEach(0..<16, id: \.self) { c in
            ramCell(cpu, addr: r * 16 + c, marAddr: marAddr)
          }
        }
      }
    }
    .font(monoSmall)
  }
  
  private func ramCell(_ cpu: Emulator, addr: Int, marAddr: Int?) -> some View {
    let inRange = addr < cpu.spec.ramSize
    let v = inRange ? cpu.ram[addr] : 0
    let isMAR = inRange && marAddr == addr
    let isPC = inRange && cpu.shared && addr == Int(cpu.pc) % cpu.spec.ramSize
    return Text(inRange ? hex2(Int(v)) : "")
      .frame(width: 24)
      .foregroundStyle(Color.primary.opacity(v == 0 ? 0.3 : 1))
      .background(RoundedRectangle(cornerRadius: 3)
        .fill(isMAR ? Color.accentColor.opacity(0.35) : Color.clear))
      .overlay(RoundedRectangle(cornerRadius: 3)
        .stroke(isPC ? Color.orange : Color.clear, lineWidth: 1))
  }
}

// MARK: - リファレンス (CPU 定義から自動生成) ----------------------------------------

struct RefLine: Identifiable {
  let title: String
  let text: String
  var id: String { title }
}

struct ReferencePane: View {
  let spec: CPUSpec
  
  var body: some View {
    List {
      Section("命令  (\(spec.name))") {
        ForEach(spec.instructions, id: \.name) { d in
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(specColor(d.colorName)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
              Text(d.syntax).font(mono).bold()
              Text(d.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(d.spacedPattern).font(monoSmall).foregroundStyle(.secondary)
          }
        }
        Text("i = 即値   S = ソースレジスタ   D = 宛先レジスタ   . = 未使用 (0)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      refSection("レジスタ", registerLines)
      refSection("疑似命令・書式", syntaxLines)
      refSection("エミュレータの動作", behaviorLines)
    }
  }
  
  private func refSection(_ title: String, _ lines: [RefLine]) -> some View {
    Section(title) {
      ForEach(lines) { l in
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(l.title)
            .font(mono)
            .bold()
            .frame(width: 150, alignment: .leading)
          Text(l.text)
            .font(.callout)
            .foregroundStyle(.secondary)
          Spacer()
        }
      }
    }
  }
  
  private var registerLines: [RefLine] {
    spec.registers.map { r in
      var roles: [String] = []
      if r.code == spec.accumulator { roles.append("ALU の演算対象") }
      if r.code == spec.addressRegister { roles.append("RAM アドレス") }
      if r.code == spec.liRegister { roles.append("LI の書き込み先") }
      let suffix = roles.isEmpty ? "" : " — " + roles.joined(separator: " / ")
      return RefLine(title: r.name, text: "コード \(r.code)" + suffix)
    }
  }
  
  private var syntaxLines: [RefLine] {
    var lines: [RefLine] = []
    if let li = spec.liRegister {
      let names = spec.liSteps.map { spec.instructions[$0.instruction].name }.joined(separator: " + ")
      lines.append(RefLine(title: "LI imm8",
                           text: "\(spec.registerName(li)) に 8bit 即値をロード (\(names) に展開)"))
      lines.append(RefLine(title: "ジャンプ label",
                           text: "ジャンプ命令にラベル/数値を渡すと LI + ジャンプに展開。\(spec.registerName(li)) は上書きされる"))
    }
    lines.append(RefLine(title: ".byte a, b, …", text: "バイト値をそのまま配置 (-128〜255)"))
    lines.append(RefLine(title: ".org addr", text: "アドレス addr まで 0 で埋める"))
    lines.append(RefLine(title: "label:", text: "ラベル定義。命令と同じ行にも書ける"))
    lines.append(RefLine(title: "数値・コメント", text: "10進 / 0x16進 / 0b2進。コメントは ; または //"))
    return lines
  }
  
  private var behaviorLines: [RefLine] {
    let carryText: String
    if spec.subCarryInverted {
      carryText = "ADD / INC は桁あふれで 1、SUB / DEC は借りが出ないとき 1"
    } else {
      carryText = "ADD / INC は桁あふれで 1、SUB / DEC は借りが出たとき 1"
    }
    return [
      RefLine(title: "メモリ",
              text: "プログラム最大 \(spec.programSize) バイト / RAM \(spec.ramSize) バイト"),
      RefLine(title: "carry",
              text: carryText + (spec.logicClearsCarry ? "。論理演算は 0" : "。論理演算は変化なし")),
      RefLine(title: "zero", text: "ALU 結果が 0 のとき 1。ALU 以外の命令はフラグを変えない"),
      RefLine(title: "停止", text: "プログラム終端 / HALT / ジャンプ後に全く同じ状態へ戻ったとき"),
    ]
  }
}

// MARK: - CPU 定義 (JSON) エディタ ----------------------------------------------------

struct CPUSpecPane: View {
  @ObservedObject var model: AssemblerModel
  
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 2) {
          Text(model.spec.name).font(.headline)
          Text(summaryLine)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("開く…") { model.openSpecFile() }
        Button("書き出し…") { model.saveSpecFile() }
        Button("標準に戻す") { model.resetSpecToDefault() }
      }
      .padding(8)
      
      Divider()
      
      CodeEditor(text: $model.specText, mode: .json)
      
      Divider()
      
      HStack(alignment: .top, spacing: 8) {
        statusLabel
        Spacer()
        Button("適用") { model.applySpecText() }
          .disabled(!model.specTextChanged)
      }
      .padding(8)
      
      DisclosureGroup("CPU 定義ファイルの書式") {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Self.formatHelp) { l in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(l.title).font(monoSmall).bold().frame(width: 130, alignment: .leading)
                Text(l.text).font(.caption).foregroundStyle(.secondary)
                Spacer()
              }
            }
          }
          .padding(.vertical, 4)
        }
        .frame(maxHeight: 190)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 8)
    }
  }
  
  private var summaryLine: String {
    let s = model.spec
    let li = s.liRegister.map { "LI: \(s.registerName($0))" } ?? "LI: 無効"
    return "命令 \(s.instructions.count) ・ レジスタ \(s.registers.count) ・ プログラム \(s.programSize)B ・ RAM \(s.ramSize)B ・ \(li)"
  }
  
  @ViewBuilder
  private var statusLabel: some View {
    if let e = model.specError {
      Label(e, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
    } else if model.specTextChanged {
      Label("未適用の変更があります", systemImage: "pencil.circle")
        .foregroundStyle(.orange)
        .font(.callout)
    } else {
      Label("適用済み", systemImage: "checkmark.circle")
        .foregroundStyle(.green)
        .font(.callout)
    }
  }
  
  private static let formatHelp: [RefLine] = [
    RefLine(title: "name", text: "CPU の名前 (ウィンドウのサブタイトルに表示)"),
    RefLine(title: "programSize / ramSize", text: "命令メモリ / RAM のバイト数 (1〜256)"),
    RefLine(title: "sharedMemory", text: "true なら命令を RAM 上に置く (エミュレータの初期値)"),
    RefLine(title: "registers", text: "{ \"名前\": コード }。S / D フィールドに入れる番号"),
    RefLine(title: "accumulator", text: "ALU 命令の演算対象レジスタ"),
    RefLine(title: "addressRegister", text: "load / store が RAM アドレスに使うレジスタ"),
    RefLine(title: "flags.subCarry", text: "\"borrow\" (借りで carry=1) / \"inverted\" (借りなしで carry=1)"),
    RefLine(title: "flags.logicClearsCarry", text: "true なら AND/OR/XOR/NOT で carry=0"),
    RefLine(title: "pattern", text: "8 文字。左端が bit7。0 1 = 固定ビット / i = 即値 / S = ソース / D = 宛先 / X か . = 未使用"),
    RefLine(title: "exec", text: "set_bits (reg と bits:[下位,上位] が必要) / load / store / jump / jump_if_carry / jump_if_not_carry / jump_if_zero / jump_if_not_zero / move / not / and / or / xor / add / sub / inc / dec / nop / halt"),
    RefLine(title: "operands", text: "アセンブリ上の引数順 (\"D\" \"S\" \"I\")。省略時は D, S, I の順"),
    RefLine(title: "summary / color", text: "リファレンス用の説明 (省略可) と色 (red orange teal green blue purple pink)"),
    RefLine(title: "LI の自動生成", text: "同じレジスタへの set_bits 命令で 8bit が過不足なく埋まるとき LI が使える"),
  ]
}
