#!/usr/bin/env python3
"""
Gera o relatório final (LaTeX -> PDF).

1. Lê as saídas reais da última execução (pasta evidencias/) e grava
   relatorio/numeros.tex com os números citados no texto (casos de teste,
   índices, chaves estrangeiras...), para que o relatório nunca contradiga a
   execução. Recusa gerar se algum caso de teste tiver falhado.
2. Compila relatorio/relatorio.tex com latexmk: usa o TeX Live local se ele
   tiver todos os pacotes; senão, a imagem Docker texlive/texlive:latest-medium.

Uso (na raiz do repositório, depois de ./run_all.sh):
    python3 relatorio/gerar_relatorio.py

Saída: relatorio/Relatorio_Trabalho_BD2.pdf
(Também é possível compilar relatorio.tex no Overleaf, enviando junto o numeros.tex.)
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path

RAIZ = Path(__file__).resolve().parent.parent
DIR = RAIZ / "relatorio"
EVID = RAIZ / "evidencias"
NOME_PDF = "Relatorio_Trabalho_BD2"
IMAGEM_TEX = "texlive/texlive:latest-medium"
PACOTES = ["babel.sty", "portuguese.ldf", "lmodern.sty", "microtype.sty", "booktabs.sty", "tabularx.sty",
           "enumitem.sty", "caption.sty", "listings.sty", "tikz.sty", "hyperref.sty"]


class Erro(Exception):
    pass


def ler(nome: str) -> str:
    arq = EVID / nome
    if not arq.is_file():
        raise Erro(f"evidência não encontrada: evidencias/{nome} (execute ./run_all.sh)")
    return arq.read_text(encoding="utf-8")


def linhas_por_grupo(nome: str) -> Counter:
    """Conta os casos OK por letra inicial do código do caso; falha se houver FALHOU."""
    grupos: Counter = Counter()
    for linha in ler(nome).splitlines():
        m = re.match(r"^\s*([A-Z])\d+\w*\s*\|.*\|\s*(OK|FALHOU)\s*$", linha)
        if not m:
            continue
        if m.group(2) == "FALHOU":
            raise Erro(f"evidencias/{nome}: há caso FALHOU — corrija antes de gerar o relatório")
        grupos[m.group(1)] += 1
    if not grupos:
        raise Erro(f"evidencias/{nome}: nenhum caso encontrado")
    return grupos


def primeira_contagem(nome: str) -> int:
    m = re.search(r"^\((\d+) rows?\)", ler(nome), re.M)
    if not m:
        raise Erro(f"evidencias/{nome}: contagem de linhas não encontrada")
    return int(m.group(1))


def escapar_latex(texto: str) -> str:
    trocas = {"\\": r"\textbackslash{}", "&": r"\&", "%": r"\%", "$": r"\$", "#": r"\#", "_": r"\_",
              "{": r"\{", "}": r"\}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}
    return "".join(trocas.get(c, c) for c in texto)


def gerar_numeros() -> None:
    log = ler("run_all.log")
    if "Execução concluída com sucesso!" not in log or "FALHOU" in log:
        raise Erro("a última execução do run_all.sh não terminou com sucesso")

    dte = linhas_por_grupo("p1_q5_cenario_teste.txt")
    p2 = linhas_por_grupo("p2_testes_regras.txt")
    # Casos S: os executados como bd2_app (ACEITO/REJEITADO) e as verificações
    # de resultado feitas pelo administrador (esperado VERDADEIRO)
    linhas_s = [l for l in ler("p2_testes_regras.txt").splitlines() if re.match(r"^\s*S\d+\s*\|", l)]
    verif_s = sum(1 for l in linhas_s if l.split("|")[2].strip() == "VERDADEIRO")

    prova = {}
    for linha in ler("p1_q4_prova.txt").splitlines():
        partes = [p.strip() for p in linha.split("|")]
        if len(partes) == 6 and partes[0] in ("public", "bd2_q4_prova"):
            prova[partes[0]] = partes[1:]
    if len(prova) != 2 or prova["public"] != prova["bd2_q4_prova"]:
        raise Erro("evidencias/p1_q4_prova.txt: a estrutura gerada não coincide com a original")
    tabelas, pks, fks, colunas, notnull = prova["public"]

    conc = ler("p2_concorrencia.txt")
    m = re.search(r"N = (\d+) sessões", conc)
    if not m or "OK: Testes de concorrência passaram." not in conc:
        raise Erro("evidencias/p2_concorrencia.txt: testes de concorrência ausentes ou com falha")

    arq_int = DIR / "integrantes.txt"
    nomes = [n.strip() for n in arq_int.read_text(encoding="utf-8").splitlines()
             if n.strip() and not n.lstrip().startswith("#")] if arq_int.is_file() else []
    integrantes = r" \\ ".join(escapar_latex(n) for n in nomes) or r"[preencher relatorio/integrantes.txt]"

    macros = {
        "integrantes": integrantes,
        "numIndicesPublic": primeira_contagem("p1_q1_indices.txt"),
        "numFKsPublic": primeira_contagem("p1_q3_foreign_keys.txt"),
        "numQquatroTabelas": tabelas, "numQquatroPKs": pks, "numQquatroFKs": fks,
        "numQquatroColunas": colunas, "numQquatroNotNull": notnull,
        "numCasosDTE": sum(dte.values()),
        **{f"numDTE{g.lower()}": dte.get(g, 0) for g in "ABCDEF"},
        "numCasosH": p2.get("H", 0), "numCasosT": p2.get("T", 0),
        "numCasosS": p2.get("S", 0), "numCasosP": p2.get("P", 0),
        "numCasosSApp": p2.get("S", 0) - verif_s, "numVerifS": verif_s,
        "numSessoes": m.group(1),
    }
    texto = ["% Gerado por relatorio/gerar_relatorio.py a partir de evidencias/. Não editar à mão."]
    texto += [f"\\newcommand{{\\{k}}}{{{v}}}" for k, v in macros.items()]
    (DIR / "numeros.tex").write_text("\n".join(texto) + "\n", encoding="utf-8")
    print("numeros.tex gerado:", ", ".join(f"{k}={v}" for k, v in macros.items() if k != "integrantes"))


def tex_local_completo() -> bool:
    if not shutil.which("latexmk") or not shutil.which("kpsewhich"):
        return False
    return all(subprocess.run(["kpsewhich", p], capture_output=True, text=True).stdout.strip() for p in PACOTES)


def compilar() -> None:
    args = ["latexmk", "-pdf", "-interaction=nonstopmode", "-halt-on-error",
            "-outdir=build", f"-jobname={NOME_PDF}", "relatorio.tex"]
    if tex_local_completo():
        print("Compilando com o TeX Live local...")
        cmd = args
    elif shutil.which("docker"):
        print(f"TeX Live local incompleto; compilando com a imagem Docker {IMAGEM_TEX}...")
        usuario = [f"--user={os.getuid()}:{os.getgid()}"] if hasattr(os, "getuid") else []
        cmd = ["docker", "run", "--rm", *usuario, "-e", "HOME=/tmp",
               "-v", f"{DIR}:/work", "-w", "/work", IMAGEM_TEX, *args]
    else:
        raise Erro("sem TeX Live completo nem Docker: compile relatorio.tex + numeros.tex no Overleaf")

    proc = subprocess.run(cmd, cwd=DIR, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if proc.returncode != 0:
        print(proc.stdout[-3000:], proc.stderr[-2000:], sep="\n", file=sys.stderr)
        raise Erro("falha na compilação LaTeX (veja relatorio/build/*.log)")
    shutil.copy2(DIR / "build" / f"{NOME_PDF}.pdf", DIR / f"{NOME_PDF}.pdf")
    print(f"PDF gerado: relatorio/{NOME_PDF}.pdf")


def main() -> int:
    try:
        gerar_numeros()
        compilar()
    except Erro as e:
        print("ERRO:", e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
