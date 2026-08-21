//Last step
use crate::codegen::{AsmInst, AsmOperand};
use std::fmt::Write;

pub fn generate_assembly(asm_in: Vec<AsmInst>) -> Result<String, std::fmt::Error> {
    let mut assembly = String::new();

    writeln!(assembly, "~Init_000:")?;
    writeln!(assembly, "\tXOR [rx31, rx31]")?;
    writeln!(assembly, "\tXOR [rx30, rx30]")?;

    for inst in asm_in {
        match inst {
            AsmInst::Mov(dest, src, imm) => {
                writeln!(assembly, "\tMOV {} <- {} {}", dest, src, imm)?
            }
            AsmInst::Add(dest, src1, src2, imm2) => {
                writeln!(assembly, "\tADD {} <- [{}, {} {}]", dest, src1, src2, imm2)?
            }
            AsmInst::Sub(dest, src1, src2, imm2) => {
                writeln!(assembly, "\tSUB {} <- [{}, {} {}]", dest, src1, src2, imm2)?
            }
            AsmInst::Mul(dest, src1, src2, imm2) => {
                writeln!(assembly, "\tMUL {} <- [{}, {} {}]", dest, src1, src2, imm2)?
            }
            AsmInst::Div(dest, src1, src2, imm2) => {
                writeln!(assembly, "\tDIV {} <- [{}, {} {}]", dest, src1, src2, imm2)?
            }
            AsmInst::Sdiv(dest, src1, src2, imm2) => {
                writeln!(assembly, "\tSDIV {} <- [{}, {} {}]", dest, src1, src2, imm2)?
            }
            AsmInst::Mod(dest, src1, src2, imm2) => {
                writeln!(assembly, "\tMOD {} <- [{}, {} {}]", dest, src1, src2, imm2)?
            }
            AsmInst::Xor(dest, src, imm) => {
                writeln!(assembly, "\tXOR [{}, {} {}]", dest, src, imm)?
            }
            AsmInst::Or(dest, src, imm) => writeln!(assembly, "\tOR  [{}, {} {}]", dest, src, imm)?,
            AsmInst::And(dest, src, imm) => {
                writeln!(assembly, "\tAND [{}, {} {}]", dest, src, imm)?
            }
            AsmInst::Shl(dest, src, imm) => {
                writeln!(assembly, "\tSHL [{}, {} {}]", dest, src, imm)?
            }
            AsmInst::Shr(dest, src, imm) => {
                writeln!(assembly, "\tSHR [{}, {} {}]", dest, src, imm)?
            }
            AsmInst::Sra(dest, src, imm) => {
                writeln!(assembly, "\tSRA [{}, {} {}]", dest, src, imm)?
            }

            AsmInst::Not(op) => writeln!(assembly, "\tNOT {}", op)?,
            AsmInst::Load(dest, imm18) => writeln!(assembly, "\tLOAD {} <- {}", dest, imm18)?,
            AsmInst::Lma(imm26) => writeln!(assembly, "\tLMA {}", imm26)?,

            AsmInst::Ldr(dest, base, offset) => {
                writeln!(assembly, "\tLDR {} <- [{} {}]", dest, base, offset)?
            }
            AsmInst::Str(dest, base, offset) => {
                writeln!(assembly, "\tSTR {} -> [{} {}]", dest, base, offset)?
            }

            AsmInst::SprLdr(rx0, spr, imm16) => {
                writeln!(assembly, "\tSPRLDR {} <- [{:?} {}]", rx0, spr, imm16)?
            }
            AsmInst::SprStr(rx0, spr, imm16) => {
                writeln!(assembly, "\tSPRSTR {} -> [{:?} {}]", rx0, spr, imm16)?
            }
            AsmInst::SprAdd(rx0, spr, imm16) => {
                writeln!(assembly, "\tSPRADD {} ->{:?}<- {}", rx0, spr, imm16)?
            }
            AsmInst::SprSub(rx0, spr, imm16) => {
                writeln!(assembly, "\tSPRSUB {} ->{:?}<- {}", rx0, spr, imm16)?
            }
            AsmInst::SprLea(rx0, spr, imm16) => {
                writeln!(assembly, "\tSPRLEA {} <- [{:?} {}]", rx0, spr, imm16)?
            }
            AsmInst::SprSet(rx0, spr) => writeln!(assembly, "\tSPRSET {} -> {:?}", rx0, spr)?,
            AsmInst::Push(rx0) => writeln!(assembly, "\tPUSH <- {}", rx0)?,
            AsmInst::Pop(rx0) => writeln!(assembly, "\tPOP -> {}", rx0)?,

            AsmInst::Cmp(rx0, rx1, imm10) => writeln!(assembly, "\tCMP {} <-> [{}, {}]", rx0, rx1, imm10)?,
            AsmInst::Beq(lbl) => writeln!(assembly, "\tBEQ -> {}\n", lbl)?,
            AsmInst::Bne(lbl) => writeln!(assembly, "\tBNE -> {}\n", lbl)?,
            AsmInst::Bgu(lbl) => writeln!(assembly, "\tBGU -> {}\n", lbl)?,
            AsmInst::Bsu(lbl) => writeln!(assembly, "\tBSU -> {}\n", lbl)?,
            AsmInst::Bgs(lbl) => writeln!(assembly, "\tBGS -> {}\n", lbl)?,
            AsmInst::Bss(lbl) => writeln!(assembly, "\tBSS -> {}\n", lbl)?,
            AsmInst::Jmp(lbl) => writeln!(assembly, "\tJMP -> {}\n", lbl)?,
            AsmInst::Jr(rx0) => writeln!(assembly, "\tJR  -> {}", rx0)?,
            AsmInst::Call(lbl) => writeln!(assembly, "\tCALL {}\n", lbl)?,
            AsmInst::Inline(asm) => writeln!(assembly, "\t{}", asm)?,
            AsmInst::Label(lbl) => writeln!(assembly, "\n{}:", lbl)?,
            AsmInst::Ret => writeln!(assembly, "\tRET")?,
        }
    }
    Ok(assembly)
}
