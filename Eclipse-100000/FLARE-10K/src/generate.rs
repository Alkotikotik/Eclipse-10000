//Last step
use crate::codegen::AsmInst;
use std::fmt::Write;

pub fn generate_assembly(asm_in: Vec<AsmInst>) -> Result<String, std::fmt::Error> {
    let mut assembly = String::new();

    writeln!(assembly, "XOR [rx31, rx31]")?;
    writeln!(assembly, "XOR [rx30, rx30]")?;

    for inst in asm_in {
        match inst {
            AsmInst::Mov(dest, src, imm) => {
                writeln!(assembly, "MOV {:?} <- {:?} {:?}", dest, src, imm)?
            }

            AsmInst::Add(dest, src1, src2, imm2) => writeln!(
                assembly,
                "ADD {:?} <- [{:?}, {:?} {:?}]",
                dest, src1, src2, imm2
            )?,
            AsmInst::Sub(dest, src1, src2, imm2) => writeln!(
                assembly,
                "SUB {:?} <- [{:?}, {:?} {:?}]",
                dest, src1, src2, imm2
            )?,
            AsmInst::Mul(dest, src1, src2, imm2) => writeln!(
                assembly,
                "MUL {:?} <- [{:?}, {:?} {:?}]",
                dest, src1, src2, imm2
            )?,

            AsmInst::Xor(dest, src, imm) => {
                writeln!(assembly, "XOR [{:?}, {:?} {:?}]", dest, src, imm)?
            }
            AsmInst::Or(dest, src, imm) => {
                writeln!(assembly, "OR  [{:?}, {:?} {:?}]", dest, src, imm)?
            }
            AsmInst::And(dest, src, imm) => {
                writeln!(assembly, "AND [{:?}, {:?} {:?}]", dest, src, imm)?
            }
            AsmInst::Shl(dest, src, imm) => {
                writeln!(assembly, "SHL [{:?}, {:?} {:?}]", dest, src, imm)?
            }
            AsmInst::Shr(dest, src, imm) => {
                writeln!(assembly, "SHR [{:?}, {:?} {:?}]", dest, src, imm)?
            }
            AsmInst::Sra(dest, src, imm) => {
                writeln!(assembly, "SRA [{:?}, {:?} {:?}]", dest, src, imm)?
            }

            AsmInst::Not(op) => writeln!(assembly, "NOT {:?}", op)?,
            AsmInst::Load(dest, imm18) => writeln!(assembly, "LOAD {:?} <- {:?}", dest, imm18)?,
            AsmInst::Lma(imm26) => writeln!(assembly, "LMA {:?}", imm26)?,

            AsmInst::Ldr(dest, base, offset) => {
                writeln!(assembly, "LDR {:?} <- [{:?} {:?}]", dest, base, offset)?
            }
            AsmInst::Str(dest, base, offset) => {
                writeln!(assembly, "STR {:?} -> [{:?} {:?}]", dest, base, offset)?
            }

            AsmInst::SprLdr(rx0, spr, imm16) => {
                writeln!(assembly, "SPRLDR {:?} <- [{:?} {:?}]", rx0, spr, imm16)?
            }
            AsmInst::SprStr(rx0, spr, imm16) => {
                writeln!(assembly, "SPRSTR {:?} -> [{:?} {:?}]", rx0, spr, imm16)?
            }
            AsmInst::SprAdd(rx0, spr, imm16) => {
                writeln!(assembly, "SPRADD {:?} ->{:?}<- {:?}", rx0, spr, imm16)?
            }
            AsmInst::SprSub(rx0, spr, imm16) => {
                writeln!(assembly, "SPRSUB {:?} ->{:?}<- {:?}", rx0, spr, imm16)?
            }
            AsmInst::SprLea(rx0, spr, imm16) => {
                writeln!(assembly, "SPRLEA {:?} <- [{:?} {:?}]", rx0, spr, imm16)?
            }
            AsmInst::SprSet(rx0, spr) => writeln!(assembly, "SPRSET {:?} -> {:?}", rx0, spr)?,
            AsmInst::Push(rx0) => writeln!(assembly, "PUSH <- {:?}", rx0)?,
            AsmInst::Pop(rx0) => writeln!(assembly, "POP -> {:?}", rx0)?,

            AsmInst::Cmp(rx0, rx1) => writeln!(assembly, "CMP {:?} <-> {:?}", rx0, rx1)?,
            AsmInst::Beq(lbl) => writeln!(assembly, "BEQ -> {:?}", lbl)?,
            AsmInst::Bne(lbl) => writeln!(assembly, "BNE -> {:?}", lbl)?,
            AsmInst::Bgu(lbl) => writeln!(assembly, "BGU -> {:?}", lbl)?,
            AsmInst::Bsu(lbl) => writeln!(assembly, "BSU -> {:?}", lbl)?,
            AsmInst::Bgs(lbl) => writeln!(assembly, "BGS -> {:?}", lbl)?,
            AsmInst::Bss(lbl) => writeln!(assembly, "BSS -> {:?}", lbl)?,
            AsmInst::Jmp(lbl) => writeln!(assembly, "JMP -> {:?}", lbl)?,
            AsmInst::Jr(rx0) => writeln!(assembly, "JR  -> {:?}", rx0)?,
            AsmInst::Call(lbl) => writeln!(assembly, "CALL {:?}", lbl)?,
            AsmInst::Inline(asm) => writeln!(assembly, "{:?}", asm)?,
            AsmInst::Label(lbl) => writeln!(assembly, "~{:?}", lbl)?,
            AsmInst::Ret => writeln!(assembly, "RET")?,
        }
    }
    Ok(assembly)
}
