# Scriba – a Lotus plugin: your school folder becomes text for Claude, one file per subject, made on this Mac.
#   lotus scriba · /scriba                  the app: drop the school folder, the subjects, convert, settings
#   /scriba reload [subject|alle] [--neu]   convert what is new or changed – without a subject it asks which
#   /scriba einstellungen                   the settings
#   /scriba prompt                          the coach prompt for the Claude project → clipboard
#   /scriba ordner <folder>                 choose the school folder
# Next to the school folder Scriba makes "<name> (Claude)": per subject one file with everything (Mathematik.md)
# and a folder with each file on its own (.md). The text comes from extract.swift – PDFKit, Apple's text
# recognition and the XML of Office files – built once on this Mac. A local AI (Lotus' model on this Mac, Apple
# Intelligence or Ollama) cleans up what was read from scans, pictures and formulas. While it works, the lotus of
# Lotus blooms (Lotus' own progress screen, lib/bg/progress.zsh).
# Settings: $LOTUS_PLUGIN_DATA/settings, one KEY=value per line – SC_ROOT, SC_OUT, SC_AI (auto|local|apple|ollama|
# off), SC_FOR (auto|all), SC_JOB, SC_YEAR – so a Lotus plugin pack can set them.
setopt extendedglob
zmodload zsh/datetime zsh/system 2>/dev/null
zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload -F zsh/files b:zf_mkdir 2>/dev/null

typeset -g SC_CONF=${LOTUS_PLUGIN_DATA:?Lotus starts this}/settings
typeset -g SC_ROOT= SC_OUT= SC_AI=auto SC_FOR=auto SC_YEAR=1 SC_JOB="Informatiker/in EFZ, Fachrichtung Applikationsentwicklung"
typeset -g SC_MSG= SC_BIN= SC_TMP= SC_PROVIDER= SC_AI_LABEL= SC_ERR= RS=$'\x1e' US=$'\x1f' N=$'\n' T=$'\t'
typeset -gi SC_STOP=0 SC_MODEL_STARTED=0 W=80 H=24 SC_BLOOMED=0
typeset -ga SC_SUBJ=() SC_NEW=() SC_GONE=() SC_ALL=() SC_SKIP=() SC_UL=() SC_UK=() SC_UT=()
typeset -gA SC_M=()

# What Scriba reads (extract.swift knows them), and what it leaves alone
typeset -g SC_EXT='(#i)*.(pdf|png|jpg|jpeg|heic|heif|tif|tiff|gif|bmp|webp|docx|docm|dotx|dotm|pptx|pptm|ppsx|potx|xlsx|xlsm|xltx|ipynb|doc|rtf|odt|txt|md|markdown|csv|tsv|json|xml|yml|yaml|ini|toml|log|java|py|js|mjs|ts|jsx|tsx|html|htm|css|scss|c|h|cpp|hpp|cs|sql|sh|zsh|bash|ps1|bat|php|kt|swift|go|rs|rb|vb|vbs|r|m|pl|lua|dart)'
typeset -g SC_JUNK='(#i)([~][$]*|.[~]lock*|thumbs.db|desktop.ini|*.tmp|icon?)'   # [~][$]: \~ does not work in $~

# ── Settings ──────────────────────────────────────────────────

load() {
  local line
  [[ -r $SC_CONF ]] || return 0
  for line in "${(@f)$(<$SC_CONF)}"; do
    case $line in
      SC_ROOT=*) SC_ROOT=${line#*=} ;;   SC_OUT=*) SC_OUT=${line#*=} ;;
      SC_AI=*)   SC_AI=${line#*=} ;;     SC_FOR=*) SC_FOR=${line#*=} ;;
      SC_JOB=*)  SC_JOB=${line#*=} ;;    SC_YEAR=*) SC_YEAR=${line#*=} ;;
    esac
  done
  [[ $SC_ROOT == '~'(|/*) ]] && SC_ROOT=$HOME${SC_ROOT#\~}
  [[ $SC_OUT == '~'(|/*) ]] && SC_OUT=$HOME${SC_OUT#\~}
  [[ $SC_AI == (auto|local|apple|ollama|off) ]] || SC_AI=auto
  [[ $SC_FOR == (auto|all) ]] || SC_FOR=auto
  [[ $SC_YEAR == [1-4] ]] || SC_YEAR=1
}
save() {
  print -rl -- "SC_ROOT=$SC_ROOT" "SC_OUT=$SC_OUT" "SC_AI=$SC_AI" "SC_FOR=$SC_FOR" "SC_JOB=$SC_JOB" "SC_YEAR=$SC_YEAR" >| $SC_CONF
}

# Where the text goes → REPLY: the folder of the settings, or "<school folder> (Claude)" next to it
outdir() { REPLY=${SC_OUT:-${SC_ROOT:h}/${SC_ROOT:t} (Claude)} }

# ── The subjects and their files ──────────────────────────────

# The subjects → SC_SUBJ: the folders in the school folder that have files. Files right in the school folder are
# "Allgemein"; a school folder without subfolders is one subject of its own name.
subjects() {
  local d
  local -a dirs=() own=()
  SC_SUBJ=()
  [[ -d $SC_ROOT ]] || return 1
  outdir; local out=${REPLY:A}
  for d in $SC_ROOT/*(/N); do
    [[ ${d:A} == $out ]] && continue
    dirs=($d/**/*(.NY1))
    (( ${#dirs} )) && SC_SUBJ+=(${d:t})
  done
  own=($SC_ROOT/*(.N))
  own=(${own:#*/$~SC_JUNK})
  if (( ! ${#SC_SUBJ} )); then (( ${#own} )) && SC_SUBJ=(${SC_ROOT:t})
  elif (( ${#own} )); then SC_SUBJ+=(Allgemein); fi
  (( ${#SC_SUBJ} ))
}

# The folder of a subject → REPLY
base_of() { [[ $1 == (Allgemein|${SC_ROOT:t}) && ! -d $SC_ROOT/$1 ]] && REPLY=$SC_ROOT || REPLY=$SC_ROOT/$1 }

# The files of a subject → reply (paths relative to its folder), REPLY its folder
files_of() {   # <subject>
  local base f
  local -a found
  outdir; local out=${REPLY:A}
  base_of $1; base=$REPLY
  if [[ $1 == Allgemein && $base == $SC_ROOT ]]; then found=($base/*(.Nn)); else found=($base/**/*(.Nn)); fi
  reply=()
  for f in $found; do
    [[ ${f:t} == $~SC_JUNK || ${f:A} == $out/* ]] && continue
    reply+=(${f#$base/})
  done
  REPLY=$base
}

# What a subject has done (from its list in the output folder) → SC_M: path → "size mtime chars"
man_file() { outdir; REPLY="$REPLY/.scriba/$1.tsv" }
man_load() {   # <subject>
  local line
  local -a f
  SC_M=()
  man_file $1
  [[ -r $REPLY ]] || return 0
  for line in "${(@f)$(<$REPLY)}"; do
    f=("${(@ps:\t:)line}")
    (( ${#f} == 4 )) && SC_M[$f[1]]="$f[2] $f[3] $f[4]"
  done
}
man_save() {   # <subject>
  local k
  man_file $1
  zf_mkdir -p ${REPLY:h} 2>/dev/null || mkdir -p -- ${REPLY:h}
  { for k in ${(ko)SC_M}; do print -r -- "$k$T${SC_M[$k]// /$T}"; done } >| $REPLY
}

# What is new or changed in a subject → SC_NEW, gone → SC_GONE, all it reads → SC_ALL, left alone → SC_SKIP
scan() {   # <subject> [force]
  local rel k
  local -A st
  SC_NEW=() SC_GONE=() SC_ALL=() SC_SKIP=()
  man_load $1
  files_of $1
  local base=$REPLY
  for rel in $reply; do
    if [[ $rel != $~SC_EXT ]]; then SC_SKIP+=($rel); continue; fi
    zstat -H st -- "$base/$rel" 2>/dev/null || continue
    (( st[size] > 150 * 1048576 )) && { SC_SKIP+=($rel); continue }
    SC_ALL+=($rel)
    [[ -n $2 || ${SC_M[$rel]% *} != "$st[size] $st[mtime]" ]] && SC_NEW+=($rel)
  done
  for k in ${(k)SC_M}; do (( ${SC_ALL[(Ie)$k]} )) || SC_GONE+=($k); done
}

# Words for numbers → REPLY
tokens() {   # <characters> – about 3.6 characters per token for German text
  local -i t=$(( $1 * 10 / 36 ))
  if (( t >= 1000 )); then REPLY="≈ $(( (t + 500) / 1000 ))k Tokens"; else REPLY="≈ $t Tokens"; fi
}
files_word() { (( $1 == 1 )) && REPLY="1 Datei" || REPLY="$1 Dateien" }

# ── The extractor (extract.swift), built once ─────────────────

bin_path() {
  local sum=$(md5 -q $LOTUS_PLUGIN_DIR/extract.swift 2>/dev/null)
  SC_BIN=$LOTUS_PLUGIN_DATA/bin/scriba-extract-${sum[1,12]}
}

# Builds it when needed (the stage "prep" of the progress screen is on)
bin_build() {
  bin_path
  [[ -x $SC_BIN ]] && return 0
  if ! xcode-select -p >/dev/null 2>&1 || [[ ! -x /usr/bin/swiftc ]]; then
    SC_ERR="Scriba braucht einmal Apple's Command Line Tools: xcode-select --install"; return 1
  fi
  bg_ui_note "einmalig, etwa 20 Sekunden"
  zf_mkdir -p ${SC_BIN:h} 2>/dev/null || mkdir -p -- ${SC_BIN:h}
  rm -f -- ${SC_BIN:h}/scriba-extract-*(N)
  /usr/bin/swiftc -O -swift-version 5 -o $SC_BIN.tmp $LOTUS_PLUGIN_DIR/extract.swift >| $SC_TMP/build.log 2>&1 </dev/null &
  if await $! && [[ -x $SC_BIN.tmp ]]; then mv -f -- $SC_BIN.tmp $SC_BIN; return 0; fi
  rm -f -- $SC_BIN.tmp
  (( SC_STOP )) || SC_ERR="Die Texterkennung liess sich nicht bauen: ${$(grep -m1 'error:' $SC_TMP/build.log 2>/dev/null):-siehe swiftc}"
  return 1
}

# ── Waiting while the lotus blooms ────────────────────────────

stage() { (( BGU_LIVE )) && bg_ui_stage $1 }   # without a terminal convert prints one line per file instead

kill_tree() { local c; for c in ${(f)"$(pgrep -P $1 2>/dev/null)"}; do kill_tree $c; done; kill $1 2>/dev/null }

# Waits for a job in the background and draws the progress screen in between → its status (1 when stopped)
await() {   # <pid> [<at most seconds>]
  local -i pid=$1 limit=${2:-0}
  local -F t0=$EPOCHREALTIME
  while kill -0 $pid 2>/dev/null; do
    if (( SC_STOP || (limit && EPOCHREALTIME - t0 > limit) )); then kill_tree $pid; wait $pid 2>/dev/null; return 1; fi
    bg_ui_frame; bg_ui_tick 8
  done
  wait $pid
}

# <file> <out>: the text of a file into <out>, with its pages on the progress screen → status; SC_ERR the reason
extract() {
  local line fd what=Seite
  local -a w
  local -i more rc=1
  case ${(L)1:e} in pptx|pptm|ppsx|potx) what=Folie ;; xlsx|xlsm|xltx) what=Blatt ;; esac
  SC_ERR= _BG_BUF=
  exec {fd}< <($SC_BIN $1 $2 </dev/null 2>/dev/null; print -r -- "SC-EXIT $?")
  while :; do
    bg_read_lines $fd 0.08; more=$?
    for line in $reply; do
      case $line in
        SC-EXIT\ <->) rc=${line#* } ;;
        page\ <->\ <->) w=(${=line}); (( w[3] > 1 )) && bg_ui_note "$what $w[2] von $w[3]" ;;
        error\ *) SC_ERR=${line#error } ;;
      esac
    done
    bg_ui_frame
    (( more == 0 && ! SC_STOP )) || break
  done
  exec {fd}<&-
  (( SC_STOP )) && return 1
  (( rc == 0 )) || SC_ERR=${SC_ERR:-nicht lesbar}
  return rc
}

# The units of an extraction → SC_UL (labels), SC_UK (kinds), SC_UT (texts)
units_of() {   # <file>
  local raw u head
  raw=$(<$1)
  SC_UL=() SC_UK=() SC_UT=()
  for u in "${(@ps:$RS:)raw}"; do
    [[ $u == *$'\n'* ]] || continue
    head=${u%%$'\n'*}
    SC_UL+=("${head%%$US*}") SC_UK+=("${head#*$US}") SC_UT+=("${${u#*$N}%%$N#}")
  done
}

# ── The local AI ──────────────────────────────────────────────

need_ai() { (( $+functions[lotus_ai_run] )) || source $LOTUS_ROOT/lib/cmd/ai.zsh }

# Which AI cleans up → SC_PROVIDER (local|apple|ollama, empty: none) and SC_AI_LABEL. With "exact" Apple
# Intelligence is asked whether it is turned on (that needs Lotus' AI program, built once).
ai_resolve() {   # [exact]
  local p
  local -a order=(local apple ollama)
  need_ai
  SC_PROVIDER=
  case $SC_AI in
    off) SC_AI_LABEL=aus; return 1 ;;
    local|apple|ollama) order=($SC_AI) ;;
  esac
  for p in $order; do
    case $p in
      local)  _llm_ok || continue; _llm_row $LOTUS_AI_LOCAL; SC_AI_LABEL="$reply[2] · auf dem Mac" ;;
      apple)  _ai_apple_ok ${1:+build} 2>/dev/null || continue; SC_AI_LABEL="Apple Intelligence" ;;
      ollama) _ai_ollama_model 2>/dev/null || continue; SC_AI_LABEL="Ollama · $REPLY" ;;
    esac
    SC_PROVIDER=$p
    return 0
  done
  SC_AI_LABEL="keine KI auf diesem Mac"
  return 1
}

# The model on this Mac: started once for the whole run (and stopped again at the end, when Scriba started it)
model_up() {
  [[ $SC_PROVIDER == local ]] || return 0
  curl -fsS -m 1 http://127.0.0.1:$LLM_PORT/v1/models >/dev/null 2>&1 && ! _llm_stale && return 0
  bg_ui_note "$SC_AI_LABEL wird geladen …"
  ( LOTUS_AI_EFFORT=low _llm_start ) >/dev/null 2>&1 </dev/null &
  await $! || return 1
  SC_MODEL_STARTED=1
}
model_down() {
  (( SC_MODEL_STARTED )) || return 0
  _llm_kill >/dev/null 2>&1
  SC_MODEL_STARTED=0
}

typeset -g SC_SYS='You clean up text that was read from a school document, so that another AI can learn from it. The text came from text recognition of a scan, photo or screenshot, or from a PDF that broke its formulas apart.

Write the same content again as clean, compact Markdown:
- Keep everything that carries meaning: headings, explanations, definitions, examples, tasks, numbers, units, calculations, solutions, code. Never add, explain, summarize, translate or solve anything.
- Keep the language of the text (usually German; Swiss German spelling writes ss, never ß).
- Repair: join words and lines that were broken apart, and fix clear recognition mistakes (0/O, 1/l/I, rn/m, a lost umlaut) – only when you are sure.
- Leave out what carries no meaning: page numbers, scraps of menus and buttons in screenshots, single letters, broken fragments.
- Structure: ## for headings, - for lists, Markdown tables for tables, code in ``` blocks with its language.
- Formulas and calculations in LaTeX: $…$ inside a line, $$…$$ on a line of their own – never \( \) or \[ \]. Use \frac{a}{b}, x^{2}, \sqrt{x}, \cdot. Put formulas back together that were broken apart (numerator and denominator on separate lines, x2 meaning x^{2}) when the meaning is clear; otherwise leave them as they are.
- Steps of an equation stay one per line with their operation after a bar, as written: 2x + 5 = 17 | -5. Never draw lines, boxes or separators that are not in the text.
- Mark what cannot be read with [?].
Answer with the Markdown only: no introduction, no remarks, no ``` around the whole answer.'

# <message> → REPLY: the answer of the AI, tidied; status 1 when it failed, was stopped or took too long
ask_ai() {
  local out=$SC_TMP/ai.out
  (
    LLM_PID=0     # the model belongs to this run – lotus_ai_run must not stop it
    export LOTUS_AI_PROVIDER=$SC_PROVIDER LOTUS_AI_EFFORT=low LOTUS_AI_ENHANCE=off LOTUS_AI_INSTRUCTIONS=$SC_SYS
    lotus_ai_run --plain "$1"
  ) >| $out 2>/dev/null </dev/null &
  await $! 300 || return 1
  REPLY=$(<$out)
  REPLY=${${REPLY##[[:space:]]#}%%[[:space:]]#}
  if [[ $REPLY == '```'(markdown|md|)$'\n'* && $REPLY == *$'\n```' ]]; then REPLY=${${REPLY#*$'\n'}%$'\n'*}; fi
  [[ ${REPLY%%$'\n'*} == (#i)(here is|here\'s|hier ist|hier sind|voici)*: ]] && REPLY=${${REPLY#*$'\n'}##[[:space:]]#}
  # no spaces at line ends, no separator lines, at most one empty line in a row
  local -a ls=("${(@f)REPLY}")
  ls=("${(@)ls%%[[:space:]]##}")
  ls=("${(@)ls:#(---|\*\*\*|___)}")
  REPLY=${(F)ls}
  while [[ $REPLY == *$N$N$N* ]]; do REPLY=${REPLY//$N$N$N/$N$N}; done
  # LaTeX the way the rest is written: $…$ and $$…$$
  local o1='\( ' o2='\(' c1=' \)' c2='\)' d1='\[' d2='\]'
  REPLY=${${${${${${REPLY//$o1/\$}//$o2/\$}//$c1/\$}//$c2/\$}//$d1/\$\$}//$d2/\$\$}
  [[ -n $REPLY ]]
}

# Did the AI keep the content? Not much shorter (it summarized) and not much longer (it explained)
kept() {   # <before> <after>
  local -i a=${#${1//[[:space:]]/}} b=${#${2//[[:space:]]/}}
  (( a < 80 )) && return 0
  (( b * 100 >= a * 45 && b <= a * 3 + 400 ))
}

# Pieces of at most <n> characters, at line ends → reply
chunks() {   # <text> <n>
  local line cur=
  reply=()
  for line in "${(@f)1}"; do
    if (( ${#cur} + ${#line} > $2 )) && [[ -n $cur ]]; then reply+=("$cur"); cur=$line
    else cur=${cur:+$cur$'\n'}$line; fi
  done
  [[ -n $cur ]] && reply+=("$cur")
}

# Does a unit need the AI? Scans, formulas and pictures – with "all" plain text too
needs_ai() {
  local kd
  for kd in $SC_UK; do [[ $kd == (ocr|math|pic) || ( $SC_FOR == all && $kd == text ) ]] && return 0; done
  return 1
}

# The AI cleans up unit <i> of <file name> where it helps: scans and formulas all of it, text with pictures only
# what was read from the pictures ("all": every unit). What it changed too much stays as it was.
clean_unit() {   # <i> <file name> → SC_UT[i]
  local -i i=$1 n p
  local kind=$SC_UK[$1] text=$SC_UT[$1] where how part out= block ctx line
  local -i limit=9000
  [[ $SC_PROVIDER == apple ]] && limit=1800              # Apple's model reads about 4000 tokens
  [[ $SC_PROVIDER == ollama ]] && limit=5000
  where="${SC_UL[i]:+${SC_UL[i]} von }„$2“"
  if [[ $kind == (ocr|math) || ( $SC_FOR == all && $kind == (text|pic) ) ]]; then
    case $kind in
      ocr)  how="mit Texterkennung aus einem Scan oder Foto gelesen" ;;
      math) how="aus einem PDF – die Formeln können zerrissen sein" ;;
      *)    how="aus dem Dokument" ;;
    esac
    chunks $text $limit
    local -a parts=("${reply[@]}")
    for (( p = 1; p <= ${#parts}; p++ )); do
      (( ${#parts} > 1 )) && bg_ui_note "$where · Teil $p von ${#parts}"
      part=$parts[p]
      if ask_ai "$where, $how:"$'\n\n'"$part" && kept $part $REPLY; then out+=${out:+$'\n'}$REPLY
      else (( SC_STOP )) && return 1; out+=${out:+$'\n'}$part; fi
    done
    SC_UT[i]=$out
    return 0
  fi
  [[ $kind == pic ]] || return 0
  # only the blocks "[Bildtext]" … (up to an empty line), with the rest of the page as context
  local -a lines=("${(@f)text}") kept_lines=() around=()
  local -i inside=0
  for line in $lines; do
    if [[ $line == '[Bildtext]' ]]; then inside=1
    elif (( inside )); then [[ -z $line ]] && inside=0
    else around+=("$line"); fi
  done
  ctx=${${(F)around}[1,1500]}
  for (( n = 1; n <= ${#lines}; n++ )); do
    if [[ $lines[n] != '[Bildtext]' ]]; then kept_lines+=("$lines[n]"); continue; fi
    block=
    while (( ++n <= ${#lines} )) && [[ -n $lines[n] ]]; do block+=${block:+$'\n'}$lines[n]; done
    if ask_ai "Text read from a picture on $where – usually a screenshot. The text around the picture is only context: never repeat it, never translate anything.

Context:
$ctx

Text from the picture:
$block

Keep only what someone learning this needs: code, commands, formulas, values, error messages, labels the context refers to. Drop menus, navigation, lists of buttons, links, ads and broken scraps. Write it as compact Markdown in the language it is in – no bold, no lines or separators. If nothing is worth keeping, answer with a single -"; then
      [[ $REPLY == (-|–|—) ]] || kept_lines+=('[Bildtext]' "${(@f)REPLY}" '')
    else
      (( SC_STOP )) && return 1
      kept_lines+=('[Bildtext]' "${(@f)block}" '')
    fi
  done
  while [[ -z $kept_lines[-1] ]] && (( ${#kept_lines} )); do kept_lines[-1]=(); done
  SC_UT[i]=${(F)kept_lines}
}

# ── Making the text ───────────────────────────────────────────

# The Markdown of one file from SC_UL/SC_UK/SC_UT → REPLY
compose() {   # <path in the subject>
  local -i i
  local mark out="# Datei: $1"
  for (( i = 1; i <= ${#SC_UT}; i++ )); do
    mark=$SC_UL[i]
    if [[ $SC_UK[i] == ocr ]]; then
      if [[ ${(L)1:e} == (png|jpg|jpeg|heic|heif|tif|tiff|gif|bmp|webp) ]]; then mark=Bildtext; else mark="${mark:+$mark · }Scan"; fi
    fi
    out+="$N${mark:+[$mark]$N}$SC_UT[i]"
    (( i < ${#SC_UT} )) && out+=$'\n'
  done
  REPLY=$out
}

# The file with everything of a subject, from the .md of its files in the order of their paths
combine() {   # <subject>
  local k body= md date
  local -i n=0
  outdir; local out=$REPLY
  for k in ${(ko)SC_M}; do
    [[ ${SC_M[$k]##* } == -1 ]] && continue
    md="$out/$1/$k.md"
    [[ -r $md ]] || continue
    body+=$(<$md)$'\n\n'
    (( n++ ))
  done
  if (( ! n )); then rm -f -- "$out/$1.md"; return 0; fi
  strftime -s date %d.%m.%Y $EPOCHSECONDS
  tokens ${#body}; local tok=$REPLY
  files_word $n
  print -r -- "# Fach: $1
Scriba · $date · $REPLY · $tok
Marken: [S. n] Seite · [Folie n] · [Blatt …] Excel-Blatt · [Scan] aus einem Scan gelesen · [Bildtext] Text aus einem Bild · [?] unleserlich · Formeln in LaTeX

${body%$N$N}" >| "$out/$1.md"
}

# Converts the subjects: what is new or changed (all of it with --neu), removes what is gone, makes the file with
# everything again. On the progress screen; without a terminal one line per step. → SC_DONE (lines for the end)
typeset -ga SC_DONE=() SC_FAILED=()
typeset -gi SC_COUNT=0
convert() {   # [--neu] <subject…>
  local force= s rel src md name i
  [[ $1 == --neu ]] && { force=1; shift }
  local -a todo=() subj=("$@") errs=()
  local -A gone_of=() new_of=() skip_of=()
  for s in $subj; do
    scan $s $force
    for rel in $SC_NEW; do todo+=("$s$US$rel"); done
    new_of[$s]=${#SC_NEW} gone_of[$s]=${(pj:$US:)SC_GONE} skip_of[$s]=${#SC_SKIP}
  done
  outdir; local out=$REPLY
  SC_DONE=() SC_FAILED=() SC_COUNT=0 SC_STOP=0 UI_INT=0 BG_CANCEL=0 SC_ERR=
  zf_mkdir -p $out 2>/dev/null || mkdir -p -- $out 2>/dev/null || { SC_MSG="Kann hier nicht schreiben: $out"; return 1 }
  bin_path
  local -a stages=()
  [[ -x $SC_BIN ]] || stages+=("prep|Texterkennung vorbereiten|Vorbereiten")
  stages+=("read|Lesen|Lesen")
  (( ${#todo} )) && ai_resolve exact && stages+=("ai|KI räumt auf|KI")
  stages+=("save|Speichern|Speichern")
  bg_ui_begin Scriba $stages
  [[ -n $SC_PROVIDER ]] && bg_ui_info model $SC_AI_LABEL || bg_ui_info model "ohne KI"
  if [[ ! -x $SC_BIN ]]; then
    stage prep
    (( BGU_LIVE )) || print -u2 -r -- "  ${d}Texterkennung vorbereiten (einmalig) …${x}"
    bin_build || { bg_ui_end; SC_MSG=${SC_ERR:-Gestoppt}; return 1 }
  fi
  local -i n=${#todo} k fails=0
  for (( k = 1; k <= n; k++ )); do
    (( SC_STOP )) && break
    s=${todo[k]%%$US*} rel=${todo[k]#*$US}
    base_of $s; src=$REPLY/$rel
    bg_ui_batch $k $n
    bg_ui_reset_from read
    bg_ui_sub "$k / $n · ${rel:t}"
    (( BGU_LIVE )) || print -u2 -r -- "  ${d}$k/$n${x} $s/$rel"
    stage read
    man_load $s
    local -A st=()
    zstat -H st -- $src 2>/dev/null
    if ! extract $src $SC_TMP/units; then
      (( SC_STOP )) && break
      errs+=("${rel:t}: $SC_ERR"); (( fails++ ))
      rm -f -- "$out/$s/$rel.md"                       # an older version would be out of date
      SC_M[$rel]="$st[size] $st[mtime] -1"
      man_save $s
      continue
    fi
    units_of $SC_TMP/units
    if [[ -n $SC_PROVIDER ]] && needs_ai; then
      stage ai
      model_up || { (( SC_STOP )) && break; SC_PROVIDER=; bg_ui_info model "ohne KI (sie startete nicht)" }
      for (( i = 1; i <= ${#SC_UT}; i++ )); do
        [[ -n $SC_PROVIDER ]] || break
        [[ -n $SC_UL[i] ]] && bg_ui_note "$SC_UL[i] von ${#SC_UT}" || bg_ui_note ${rel:t}
        clean_unit $i ${rel:t} || break
      done
      (( SC_STOP )) && break
    fi
    stage save
    compose $rel
    md="$out/$s/$rel.md"
    zf_mkdir -p ${md:h} 2>/dev/null || mkdir -p -- ${md:h}
    print -r -- $REPLY >| $md
    SC_M[$rel]="$st[size] $st[mtime] ${#REPLY}"
    man_save $s
    (( SC_COUNT++ ))
    bg_ui_frame
  done
  # what is gone, and the files with everything
  for s in $subj; do
    man_load $s
    for rel in ${(ps:$US:)gone_of[$s]}; do
      rm -f -- "$out/$s/$rel.md"
      unset "SC_M[$rel]"
    done
    [[ -n ${gone_of[$s]} ]] && { man_save $s; find "$out/$s" -type d -empty -delete 2>/dev/null }
    combine $s
  done
  model_down
  if (( SC_STOP )); then bg_ui_end
  else bg_ui_complete; bg_ui_end; fi
  # the lines for the end
  local line tok
  local -a gone
  local -i chars c
  for s in $subj; do
    man_load $s
    chars=0
    for c in ${${(v)SC_M}##* }; do (( c > 0 )) && (( chars += c )); done
    tokens $chars; tok=$REPLY
    line="$s"$'\t'
    if (( new_of[$s] )); then files_word ${new_of[$s]}; line+="$REPLY umgewandelt"; else line+="aktuell"; fi
    gone=(${(ps:$US:)gone_of[$s]})
    (( ${#gone} )) && line+=", ${#gone} entfernt"
    line+=$'\t'
    [[ -r "$out/$s.md" ]] && line+="$s.md · $tok"
    SC_DONE+=("$line")
  done
  (( fails )) && SC_DONE+=("!"$'\t'"nicht lesbar: ${(j:, :)errs}"$'\t')
  SC_FAILED=($errs)
  (( SC_STOP )) && { SC_MSG="Gestoppt – was fertig ist, ist gespeichert."; return 130 }
  return 0
}

# ── The coach prompt ──────────────────────────────────────────

prompt_text() {   # → REPLY: prompt.md with the training, the year and the subjects
  local p=$(<$LOTUS_PLUGIN_DIR/prompt.md)
  subjects 2>/dev/null
  p=${p//\{\{AUSBILDUNG\}\}/$SC_JOB}
  p=${p//\{\{LEHRJAHR\}\}/$SC_YEAR}
  p=${p//\{\{FAECHER\}\}/${${(j:, :)SC_SUBJ}:-meine Fächer}}
  REPLY=$p
}
copy_prompt() {
  prompt_text
  print -rn -- $REPLY | pbcopy
  SC_MSG="${k}✓${x} Coach-Prompt kopiert – in Claude: Projekt → Anweisungen → einfügen (⌘V)"
}

# ── Screens ───────────────────────────────────────────────────

k=$'\e[1;'"${LOTUS_COLOR_KEY:-38;5;114}m" a=$'\e['"${LOTUS_COLOR_ACCENT:-38;5;151}m" d=$'\e['"${LOTUS_COLOR_DIM:-38;5;245}m"
b=$'\e[38;5;240m' r=$'\e[38;5;203m' B=$'\e[1m' x=$'\e[0m'

size() {
  local -a sz=(${=$(stty size < /dev/tty 2>/dev/null)})
  H=${sz[1]:-24} W=${sz[2]:-80}
  (( W >= 40 )) || W=80
  (( H >= 12 )) || H=24
}
at() { print -rn -- $'\e['"$1;$2H$3" }

wrap() {   # <text> <width> → reply
  local w line=
  reply=()
  for w in ${=1}; do
    if (( ${#line} + ${#w} + 1 > $2 )) && [[ -n $line ]]; then reply+=("$line"); line=$w
    else line=${line:+$line }$w; fi
  done
  [[ -n $line ]] && reply+=("$line")
}

header() {   # <list|settings|drop>
  local on=$'\e[7;'"$LOTUS_C[accent]m" s1 s2
  at 2 5 "${a}◇${x} ${B}lotus${x}${d} / ${x}${B}Scriba${x}"
  [[ $1 == drop ]] && return
  if [[ $1 == list ]]; then s1="${on} Fächer ${x}" s2="${d} Einstellungen ${x}"
  else s1="${d} Fächer ${x}" s2="${on} Einstellungen ${x}"; fi
  at 2 $(( W - 26 )) "$s1 $s2"
}

# The lotus inside the drop zone: frame <f> of the bloom, its pollen and the water under it
typeset -gi FL_Y=0 FL_X=0
flower() {   # <frame>
  local -i f=$1 i px py c
  [[ -n ${BGU_ROW[$f,1]} ]] || _bgu_render $f
  for (( i = 1; i <= BGU_ART_H; i++ )); do at $(( FL_Y + i - 1 )) $FL_X "${BGU_ROW[$f,$i]}"; done
  (( BGU_FRAME++ ))
  BGU_BLOOM=$(( (f - 1.0) / (${#BGU_PIX} - 1) ))
  _bgu_pollen 0
  local mask glyph y2=$'\e['"$LOTUS_C[key2]m"
  for (( i = 1; i <= ${#BGU_PX}; i++ )); do
    (( px = int(BGU_PX[i]) + 1, py = int(BGU_PY[i]) + 1 ))
    (( px >= 1 && px <= BGU_ART_W && py >= 1 && py <= BGU_ART_H )) || continue
    mask=${BGU_MASK[$f,$py]}
    [[ ${mask[px]} == ' ' ]] || continue
    (( BGU_PL[i] < 12 )) && glyph=• || glyph=·
    at $(( FL_Y + py - 1 )) $(( FL_X + px - 1 )) "${y2}${glyph}${x}"
  done
  local water=
  local -F v now=$EPOCHREALTIME
  local -i reach=$(( int(6 + 13 * BGU_BLOOM) ))
  for (( c = 0; c < BGU_ART_W; c++ )); do
    (( v = sin(c * 0.55 - now * 2.6) + 0.6 * sin(c * 0.21 + now * 1.3) ))
    if (( abs(c - BGU_ART_W / 2) > reach + 2 )); then water+=' '
    elif (( v > 1.05 )); then water+="${a}~"
    elif (( v > 0.55 )); then water+="${d}~"
    else water+=' '; fi
  done
  at $(( FL_Y + BGU_ART_H )) $FL_X "$water$x"
}

# A dropped line → reply (paths). Terminal gives /a/b\ c or '/a/b c'; paths typed with spaces but without quotes are
# put back together.
drop_paths() {
  local -a w=(${(Q)${(z)1}}) out=()
  local -i i=1 j
  local p
  while (( i <= ${#w} )); do
    ui_clean_path "$w[i]"; p=$REPLY
    if [[ ! -e $p ]]; then
      for (( j = i + 1; j <= ${#w}; j++ )); do
        ui_clean_path "${(j: :)w[i,j]}"
        [[ -e $REPLY ]] && { p=$REPLY; i=j; break }
      done
    fi
    out+=($p)
    (( i++ ))
  done
  reply=("${out[@]}")
}

set_root() {   # <folder>
  local f=$1
  [[ -d $f ]] || { SC_MSG="${r}Das ist kein Ordner:${x} ${f:t}"; return 1 }
  SC_ROOT=${f:A}
  subjects || { SC_MSG="${r}In „${SC_ROOT:t}“ sind keine Dateien.${x}"; SC_ROOT=; return 1 }
  save
  SC_MSG="${k}✓${x} ${SC_ROOT:t} · ${#SC_SUBJ} Fächer"
}

# The drop zone with the lotus → REPLY: "list", "settings" or "quit"
drop_screen() {
  local key line t1 t2 dash
  local -i fw inner art y i top rows pr pad
  while :; do
    size
    print -n $'\e[?25l\e[H\e[2J'
    header drop
    (( fw = W - 8 > 62 ? 62 : W - 8, inner = fw - 2 ))
    _bgu_load 2>/dev/null
    (( art = BGU_ART_W > 0 && H >= 24 && inner >= BGU_ART_W + 2, pad = H >= 28 ))
    (( top = 3 + pad, rows = art ? BGU_ART_H + 3 + 3 * pad : 7 ))
    dash=${${(l:inner::x:)}//x/╌}
    at $top 5 "${b}╭${dash}╮${x}"
    for (( i = 1; i <= rows; i++ )); do at $(( top + i )) 5 "${b}┆${x}"; at $(( top + i )) $(( 6 + inner )) "${b}┆${x}"; done
    at $(( top + rows + 1 )) 5 "${b}╰${dash}╯${x}"
    t1="Zieh deinen Schulordner hierher" t2="ein Unterordner pro Fach – Mathematik, Deutsch, M293 …"
    (( ${#t2} > inner - 2 )) && t2="ein Unterordner pro Fach"
    if (( art )); then
      FL_Y=$(( top + 1 + pad )) FL_X=$(( 6 + (inner - BGU_ART_W) / 2 ))
      y=$(( FL_Y + BGU_ART_H + 1 + pad ))
    else
      at $(( top + 2 )) $(( 4 + inner / 2 )) "  ${k}┃${x}"
      at $(( top + 3 )) $(( 4 + inner / 2 )) "${k}━━╋━━${x}"
      at $(( top + 4 )) $(( 4 + inner / 2 )) "  ${k}┃${x}"
      y=$(( top + 5 ))
    fi
    at $y $(( 6 + (inner - ${#t1}) / 2 )) "${B}${t1}${x}"
    at $(( y + 1 )) $(( 6 + (inner - ${#t2}) / 2 )) "${d}${t2}${x}"
    pr=$(( top + rows + 3 ))
    [[ -n $SC_MSG ]] && at $(( pr - 1 )) 5 "$SC_MSG"
    at $pr 5 "${a}›${x} "
    at $(( pr + 2 )) 5 "${d}${SC_ROOT:+⇥ Fächer · }esc beendet${x}"
    REPLY=
    if (( art && ! SC_BLOOMED )); then
      SC_BLOOMED=1
      for (( i = 1; i <= ${#BGU_PIX}; i++ )); do flower $i; ui_keyx 0.06; [[ $REPLY == timeout ]] || break; done
      [[ $REPLY == timeout ]] && REPLY=
    fi
    while :; do
      if [[ -z $REPLY ]]; then
        (( art )) && flower ${#BGU_PIX}
        at $pr 7 ""
        ui_keyx 0.12
      fi
      key=$REPLY REPLY=
      case $key in
        timeout|ignore|up|down|home|end|pgup|pgdn|back|enter) continue ;;
        tab|right|left) [[ -n $SC_ROOT ]] && { SC_MSG=; REPLY=list; return }; continue ;;
        esc|q|Q|interrupt) REPLY=quit; return ;;
        *)
          # the first key starts the line: the rest of a dropped path follows
          [[ $key == space ]] && key=' '
          print -n $'\e[?25h'
          at $pr 1 $'\e[K'
          line=$key
          vared -p "    %{$a%}›%{$x%} " line || break
          print -n $'\e[?25l'
          SC_MSG=
          [[ -n ${line//[[:space:]]/} ]] || break
          drop_paths "$line"
          set_root "$reply[1]" && { REPLY=list; return }
          break ;;
      esac
    done
  done
}

# The status of every subject → SC_ROW (one line each)
typeset -ga SC_ROW=()
statuses() {
  local s state info
  local -i chars c
  SC_ROW=()
  subjects
  for s in $SC_SUBJ; do
    scan $s
    chars=0
    for c in ${${(v)SC_M}##* }; do (( c > 0 )) && (( chars += c )); done
    if (( ! ${#SC_M} )); then state="${d}noch nicht umgewandelt${x}"
    elif (( ${#SC_NEW} || ${#SC_GONE} )); then
      state="${a}${#SC_NEW} neu${x}"
      (( ${#SC_GONE} )) && state+="${a}, ${#SC_GONE} weg${x}"
    else state="${k}✓${x} aktuell"; fi
    files_word ${#SC_ALL}; info=$REPLY
    (( chars )) && { tokens $chars; info+=" · $REPLY" }
    SC_ROW+=("$state"$'\t'"$info")
  done
}

# The subjects: convert one or all, open the folder, copy the prompt → REPLY: "settings", "drop" or "quit"
typeset -gi SC_SEL=1
list_screen() {
  local row state info
  local -i i y top n vis
  statuses
  while :; do
    size
    n=${#SC_SUBJ}
    (( SC_SEL > n )) && SC_SEL=n
    (( SC_SEL < 1 )) && SC_SEL=1
    print -n $'\e[?25l\e[H\e[2J'
    header list
    outdir
    at 4 5 "${B}${SC_ROOT:t}${x}${d} · $n Fächer → ${REPLY:t}${x}"
    (( vis = H - 12, vis < 3 ? (vis = 3) : 0, vis > n ? (vis = n) : 0 ))
    (( top = SC_SEL > vis ? SC_SEL - vis + 1 : 1 ))
    y=6
    for (( i = top; i < top + vis && i <= n; i++ )); do
      row=$SC_ROW[i]; state=${row%%$'\t'*}; info=${row#*$'\t'}
      if (( i == SC_SEL )); then at $y 5 "${a}›${x} ${B}${(r:18:)${SC_SUBJ[i][1,18]}}${x}  $state"
      else at $y 5 "  ${(r:18:)${SC_SUBJ[i][1,18]}}  $state"; fi
      (( W >= 72 )) && at $y 52 "${d}${info}${x}"
      (( y++ ))
    done
    (( top > 1 )) && at 5 7 "${d}↑ $(( top - 1 )) mehr${x}"
    (( top + vis <= n )) && at $y 7 "${d}↓ $(( n - top - vis + 1 )) mehr${x}"
    (( y += 2 ))
    [[ -n $SC_MSG ]] && { for row in "${(@f)SC_MSG}"; do at $y 5 "$row"; (( y++ )); done; (( y++ )) }
    at $(( y + 1 )) 5 "${d}⏎ umwandeln · a alle · o öffnen · p Prompt kopieren · ⇥ Einstellungen · esc${x}"
    ui_keyx
    case $REPLY in
      up)   (( SC_SEL = SC_SEL > 1 ? SC_SEL - 1 : n )) ;;
      down) (( SC_SEL = SC_SEL < n ? SC_SEL + 1 : 1 )) ;;
      tab|right|left) SC_MSG=; REPLY=settings; return ;;
      esc|q|Q|interrupt) REPLY=quit; return ;;
      enter|space|a|A)
        local -a which=($SC_SUBJ[SC_SEL])
        [[ $REPLY == (a|A) ]] && which=($SC_SUBJ)
        SC_MSG=
        convert $which
        done_msg $which
        UI_INT=0 SC_STOP=0
        statuses ;;
      o|O) outdir; if [[ -d $REPLY ]]; then open -- $REPLY; else SC_MSG="${d}Noch nichts umgewandelt – ⏎ wandelt das Fach um.${x}"; fi ;;
      p|P) copy_prompt ;;
      <1-9>) (( REPLY <= n )) && SC_SEL=$REPLY ;;
      *) SC_MSG= ;;
    esac
  done
}

# What a run did → SC_MSG, short: the list shows each subject's state
done_msg() {   # <subjects that were converted…>
  [[ -n $SC_MSG ]] && return      # stopped, or an error
  files_word $SC_COUNT
  if (( ! SC_COUNT && ! ${#SC_FAILED} )); then SC_MSG="${k}✓${x} Alles aktuell"
  elif (( $# == 1 )); then SC_MSG="${k}✓${x} ${B}$1${x} · $REPLY umgewandelt ${d}→ $1.md · o öffnet den Ordner${x}"
  else SC_MSG="${k}✓${x} $REPLY in $# Fächern umgewandelt ${d}· o öffnet den Ordner${x}"; fi
  (( ${#SC_FAILED} )) && SC_MSG+=$N"${r}!${x} nicht lesbar: ${SC_FAILED[1]}${${SC_FAILED[2]}:+ ${d}(+$(( ${#SC_FAILED} - 1 )))${x}}"
}

# Settings: one list, Enter changes the one under the arrow → REPLY: "list", "drop" or "quit"
settings_screen() {
  local -i sel=${1:-1} i y n=7 py
  local -a labels=("Schulordner" "Ausgabe" "KI" "KI liest" "Ausbildung" "Lehrjahr" "Neu umwandeln")
  local -a about=(
    "Der Ordner mit deinen Fächern – ein Unterordner pro Fach. ⏎ und einen anderen hierher ziehen."
    "Hier landen die Texte: pro Fach eine Datei mit allem (für Claude) und ein Ordner mit jeder Datei einzeln."
    "Räumt Text aus Scans, Bildern und Formeln auf – auf diesem Mac, nichts wird hochgeladen. ⏎ wechselt."
    "Scans, Bilder, Formeln: nur wo es hilft, schnell. Jede Seite: sauberer, dauert aber viel länger."
    "Steht im Coach-Prompt für Claude (p in den Fächern kopiert ihn)."
    "Steht im Coach-Prompt für Claude."
    "Wandelt alle Fächer noch einmal ganz um – zum Beispiel nach einer anderen KI-Einstellung.")
  local val line ask
  ai_resolve
  while :; do
    size
    print -n $'\e[?25l\e[H\e[2J'
    header settings
    y=5
    for (( i = 1; i <= n; i++ )); do
      case $i in
        1) val=${SC_ROOT:t}; [[ -n $val ]] || val="${r}noch keiner${x}" ;;
        2) outdir; val=${REPLY:t}; [[ -z $SC_OUT ]] && val+="${d} · neben dem Schulordner${x}" ;;
        3) case $SC_AI in
             auto) val="Automatisch ${d}· $SC_AI_LABEL${x}" ;;
             off)  val="${d}aus – nur Texterkennung${x}" ;;
             *)    val=$SC_AI_LABEL ;;
           esac ;;
        4) [[ $SC_FOR == all ]] && val="jede Seite" || val="Scans, Bilder, Formeln" ;;
        5) val=$SC_JOB ;;
        6) val="$SC_YEAR. Lehrjahr" ;;
        7) val="${d}alle Fächer${x}" ;;
      esac
      if (( i == sel )); then at $y 5 "${a}›${x} ${B}${(r:14:)labels[i]}${x} $val"
      else at $y 5 "  ${(r:14:)labels[i]} $val"; fi
      (( y += 2 ))
    done
    wrap "$about[sel]" $(( W - 12 > 70 ? 70 : W - 12 ))
    for line in $reply; do at $y 7 "${d}${line}${x}"; (( y++ )); done
    py=$(( y + 1 ))
    [[ -n $SC_MSG ]] && at $py 5 "$SC_MSG"
    at $(( py + 3 )) 5 "${d}↑↓ wählen · ⏎ ändern · ⇥ Fächer · esc${x}"
    ui_keyx
    SC_MSG=
    case $REPLY in
      up)   (( sel = sel > 1 ? sel - 1 : n )) ;;
      down) (( sel = sel < n ? sel + 1 : 1 )) ;;
      tab|left|right) [[ -n $SC_ROOT ]] && { REPLY=list; return }; REPLY=drop; return ;;
      esc|q|Q|interrupt) REPLY=quit; return ;;
      enter|space)
        case $sel in
          1) REPLY=drop; return ;;
          2|5)
            ask="Zieh einen Ordner hierher – ⏎ allein: neben dem Schulordner"
            (( sel == 5 )) && ask="Deine Ausbildung, z. B. Informatiker/in EFZ, Fachrichtung Plattformentwicklung"
            at $py 5 $'\e[2K'"${a}${ask}${x}"
            at $(( py + 3 )) 1 $'\e[2K'
            print -n $'\e[?25h'
            at $(( py + 1 )) 1 ""
            line=
            (( sel == 5 )) && line=$SC_JOB
            vared -p "    %{$a%}›%{$x%} " line
            print -n $'\e[?25l'
            if (( sel == 5 )); then
              [[ -n ${line//[[:space:]]/} ]] && { SC_JOB=${${line##[[:space:]]#}%%[[:space:]]#}; save }
            elif [[ -z ${line//[[:space:]]/} ]]; then SC_OUT=; save
            else
              drop_paths "$line"
              if mkdir -p -- "$reply[1]" 2>/dev/null && [[ -w $reply[1] ]]; then SC_OUT=${reply[1]:A}; save
              else SC_MSG="${r}Kann hier nicht schreiben:${x} ${reply[1]:t}"; fi
            fi ;;
          3) ai_next; ai_resolve ;;
          4) [[ $SC_FOR == all ]] && SC_FOR=auto || SC_FOR=all; save ;;
          6) (( SC_YEAR = SC_YEAR % 4 + 1 )); save ;;
          7) [[ -n $SC_ROOT ]] && subjects && { convert --neu $SC_SUBJ; done_msg $SC_SUBJ; REPLY=list; return }
             SC_MSG="${r}Zuerst einen Schulordner wählen.${x}" ;;
        esac ;;
    esac
  done
}

# The next choice for the AI: automatic, the ones this Mac has, off
ai_next() {
  local -a opts=(auto)
  need_ai
  _llm_ok && opts+=(local)
  _ai_apple_ok 2>/dev/null && opts+=(apple)
  _ai_ollama_models 2>/dev/null && opts+=(ollama)
  opts+=(off)
  local -i i=${opts[(Ie)$SC_AI]}
  SC_AI=${opts[i % ${#opts} + 1]}
  save
}

app() {
  local screen=list
  [[ -n $1 ]] && screen=$1
  if [[ -n $SC_ROOT && ! -d $SC_ROOT ]]; then SC_MSG="${r}„${SC_ROOT:t}“ ist nicht mehr da – zieh den Schulordner neu hierher.${x}"; screen=drop
  elif ! subjects; then [[ -n $SC_ROOT ]] && SC_MSG="${r}In „${SC_ROOT:t}“ sind keine Dateien.${x}"; screen=drop; fi
  while :; do
    case $screen in
      drop)     drop_screen ;;
      list)     list_screen ;;
      settings) settings_screen ;;
    esac
    [[ $REPLY == quit ]] && break
    screen=$REPLY
    UI_INT=0 SC_STOP=0
  done
  print -n $'\e[H\e[2J\e[?25h'
}

# ── Without the app ───────────────────────────────────────────

# A subject by a part of its name, in any case → REPLY; "alle" → all
find_subject() {   # <word>
  local w=${(L)1} s
  local -a hits=()
  for s in $SC_SUBJ; do [[ ${(L)s} == $w ]] && { REPLY=$s; return 0 }; done
  for s in $SC_SUBJ; do [[ ${(L)s} == *$w* ]] && hits+=($s); done
  (( ${#hits} == 1 )) && { REPLY=$hits[1]; return 0 }
  (( ${#hits} > 1 )) && REPLY="„$1“ passt zu ${(j:, :)hits}" || REPLY="Kein Fach „$1“ – es gibt: ${(j:, :)SC_SUBJ}"
  return 1
}

reload() {   # [subject|alle] [--neu]
  local force= s
  local -a which=()
  [[ $1 == --neu ]] && { force=--neu; shift }
  [[ $2 == --neu ]] && force=--neu
  [[ -d $SC_ROOT ]] && subjects || { ui_error "Noch kein Schulordner" "" "Wähle ihn mit /scriba – oder: /scriba ordner <Ordner>"; return 1 }
  if [[ -z $1 ]]; then
    ui_has_tty || { ui_error "Welches Fach?" "" "/scriba reload <Fach> – oder alle: ${(j:, :)SC_SUBJ}"; return 1 }
    statuses
    local -a opts=("Alle Fächer")
    local -i i
    for (( i = 1; i <= ${#SC_SUBJ}; i++ )); do opts+=("${(r:18:)SC_SUBJ[i]}  ${SC_ROW[i]%%$T*}"); done
    ui_choose "Welches Fach?" $opts || return 0
    (( REPLY == 1 )) && which=($SC_SUBJ) || which=($SC_SUBJ[REPLY-1])
  elif [[ ${(L)1} == (alle|all) ]]; then which=($SC_SUBJ)
  else
    find_subject $1 || { ui_error "$REPLY"; return 1 }
    which=($REPLY)
  fi
  convert $force $which
  local -i rc=$?
  report
  return rc
}

# SC_DONE as lines in the terminal
report() {
  local line s what file
  [[ -n $SC_MSG && ${#SC_DONE} -eq 0 ]] && { print -r -- "  $SC_MSG"; return }
  for line in $SC_DONE; do
    s=${line%%$'\t'*} what=${${line#*$'\t'}%%$'\t'*} file=${line##*$'\t'}
    if [[ $s == '!' ]]; then print -r -- "  ${r}!${x} $what"
    else print -r -- "  ${k}✓${x} ${B}${(r:16:)s}${x} $what${file:+${d}  → $file${x}}"; fi
  done
  outdir
  print -r -- "  ${d}Ordner: ${REPLY/#$HOME/~}${x}"
  [[ -n $SC_MSG ]] && print -r -- "  $SC_MSG"
}

# The line under Lotus' start screen: only when something is new
startup_line() {
  local s
  local -i n=0
  local -a where=()
  [[ -d $SC_ROOT ]] && subjects || return 0
  for s in $SC_SUBJ; do
    man_file $s; [[ -r $REPLY ]] || continue   # never converted: nothing to remind of
    scan $s
    (( ${#SC_NEW} )) && { (( n += ${#SC_NEW} )); where+=($s) }
  done
  (( n )) || return 0
  files_word $n
  print -r -- "Scriba: $REPLY neu in ${(j:, :)where} – /scriba reload"
}

usage() {
  print -r -- "  ${B}Scriba${x} – dein Schulordner als Lernstoff für Claude

  /scriba                     Schulordner hineinziehen, Fächer umwandeln
  /scriba reload [Fach]       Neues und Geändertes umwandeln – ohne Fach fragt es
  /scriba reload alle --neu   alles noch einmal ganz umwandeln
  /scriba einstellungen       Ordner, KI, Ausbildung
  /scriba prompt              Coach-Prompt für das Claude-Projekt kopieren
  /scriba ordner <Ordner>     den Schulordner wählen"
}

# ── Main ──────────────────────────────────────────────────────

load
if [[ $1 == __startup ]]; then startup_line; exit 0; fi

if [[ ! -r $LOTUS_ROOT/lib/ui.zsh || ! -r $LOTUS_ROOT/lib/bg/progress.zsh ]]; then
  print -r -- "Scriba läuft in Lotus 2.16 oder neuer: lotus plugin install https://github.com/Fanxy13/scriba"; exit 1
fi
source $LOTUS_ROOT/lib/core.zsh && source $LOTUS_ROOT/lib/ui.zsh && lotus_load 2>/dev/null
source $LOTUS_ROOT/lib/bg/progress.zsh            # the blooming lotus
LOTUS_L[bg_done]=Fertig LOTUS_L[bg_ctrl_c]="ctrl-c stoppt"
(( $+functions[ui_clean_path] )) || ui_clean_path() {   # Lotus 2.16
  local p=${${1##[[:space:]]##}%%[[:space:]]##}
  [[ $p == file://* ]] && { p=${p#file://}; p=${p#localhost}; p=${(g::)${p//\%/\\x}} }
  [[ $p == '~' || $p == '~/'* ]] && p=$HOME${p#\~}
  [[ $p == /* ]] || p=$PWD/$p
  REPLY=${p:a}
}
k=$'\e[1;'"$LOTUS_C[key]m" a=$'\e['"$LOTUS_C[accent]m" d=$'\e['"$LOTUS_C[dim]m" b=$'\e['"$LOTUS_C[border]m"

SC_TMP=$(mktemp -d ${TMPDIR:-/tmp}/scriba.XXXXXX)
cleanup() { model_down; rm -rf -- "$SC_TMP"; [[ -t 1 ]] && print -n $'\e[?25h' }
trap cleanup EXIT
# ctrl-c only sets a flag: the work stops cleanly, what is done stays saved
TRAPINT() { SC_STOP=1 UI_INT=1; return 0 }
_bg_cancel() { SC_STOP=1; BG_CANCEL=0 }        # Lotus' progress screen asks this

case ${(L)1} in
  '')                     ui_has_tty && [[ -t 1 ]] && app || usage ;;
  reload|update|neu)      shift; reload "$@" ;;
  einstellungen|settings) ui_has_tty && [[ -t 1 ]] && app settings || usage ;;
  prompt)
    if [[ $2 == --show || ! -t 1 ]]; then prompt_text; print -r -- $REPLY
    else copy_prompt; print -r -- "  $SC_MSG"; fi ;;
  ordner|folder)
    shift
    drop_paths "$*"
    if set_root "$reply[1]"; then print -r -- "  $SC_MSG"; else print -r -- "  $SC_MSG"; exit 1; fi ;;
  help|-h|--help)         usage ;;
  *)                      usage; exit 2 ;;
esac
