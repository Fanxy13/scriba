# Scriba

**Dein Schulordner als Lernstoff für Claude.** Ein Plugin für [Lotus](https://github.com/Fanxy13/homebrew-lotus).
*scriba* (lateinisch): der Schreiber – es schreibt deine Unterlagen als Text für Claude ab.

Scriba macht aus deinen Unterlagen – PDFs, Word, PowerPoint, Excel, Scans, Fotos von der Wandtafel, Code – pro Fach
**eine Textdatei**, die Claude lesen kann. Rechnungen und Formeln bleiben als Text erhalten. Dann gibst du Claude die
Datei in einem Projekt, und Claude wird dein persönlicher Prüfungscoach: erklärt, stellt dir Aufgaben, bewertet deine
Antworten.

Alles läuft auf deinem Mac. Nichts wird hochgeladen, bis du es selbst in Claude hochlädst.

## Installieren

Zuerst Lotus (falls du es noch nicht hast):

```bash
curl -fsSL https://raw.githubusercontent.com/Fanxy13/homebrew-lotus/main/install.sh | zsh
```

Dann Scriba:

```bash
lotus plugin install https://github.com/Fanxy13/scriba
```

Lotus zeigt, was das Plugin darf, und fragt dich. Danach ein neues Terminalfenster öffnen.

## So gehts

1. **`/scriba`** eingeben und deinen Schulordner ins Fenster ziehen – mit einem Unterordner pro Fach
   (Mathematik, Deutsch, M293 …).
2. Fach wählen und **⏎** drücken (oder **a** für alle). Die Lotusblume blüht, während Scriba umwandelt.
3. Neben deinem Schulordner liegt jetzt **«Schule (Claude)»** – darin pro Fach eine Datei mit allem, z. B.
   `Mathematik.md`.
4. In Claude ein **Projekt** erstellen und `Mathematik.md` ins Projektwissen hochladen.
5. In Scriba **p** drücken – das kopiert den Coach-Prompt. In Claude bei den **Projekt-Anweisungen** einfügen.
6. Im Chat **«Start»** schreiben – oder deine Lernziele schicken.

Neue Unterlagen? **`/scriba reload`** – es fragt, welches Fach, und wandelt nur Neues und Geändertes um.

## Book → PDF

Ein Online-Buch (Moodle-Buch, Skript, Doku) als PDF für Scriba: **[fanxy13.github.io/scriba](https://fanxy13.github.io/scriba/)** –
den Knopf in die Lesezeichenleiste ziehen, im Buch klicken, «Als PDF sichern».

## Befehle

| Befehl | Was es macht |
|---|---|
| `/scriba` | Schulordner hineinziehen, Fächer umwandeln |
| `/scriba reload` | Neues und Geändertes umwandeln – fragt, welches Fach |
| `/scriba reload mathe` | ein Fach direkt (ein Teil des Namens reicht) – oder `alle` |
| `/scriba reload alle --neu` | alles noch einmal ganz umwandeln |
| `/scriba einstellungen` | alle Einstellungen |
| `/scriba prompt` | den Coach-Prompt kopieren |

Im Fenster: **⏎** umwandeln · **a** alle · **o** Ordner öffnen · **p** Prompt kopieren · **⇥** Einstellungen.

## Was rauskommt

```
Schule (Claude)/
├── Mathematik.md          ← alles von Mathematik in einer Datei – das lädst du hoch
├── Mathematik/            ← jede Datei einzeln
│   ├── Kapitel 1/Bruchrechnen.docx.md
│   ├── Kapitel 1/Bruchrechnen.docx Bilder/   ← ihre Bilder
│   └── Tafelbild.jpg.md
├── Deutsch.md
└── …
```

So sieht es drin aus – kurz, damit es wenig Tokens braucht:

````markdown
# Datei: Kapitel 1/Bruchrechnen.docx
[S. 1]
## Bruchrechnen
Brüche addieren: $\frac{3}{4}+\frac{1}{8}=\frac{7}{8}$

[S. 2]
Was gibt diese Methode zurück?
![Bild](Bruchrechnen.docx%20Bilder/Bild-1.png)
[Bildtext]
```java
public int summe(int a, int b) {
    return a + b;
}
```
````

- **Seiten und Folien** sind markiert (`[S. 3]`, `[Folie 4]`), damit Claude sagen kann, wo etwas steht.
- **Formeln** werden zu LaTeX – aus Word und PowerPoint exakt, aus PDFs und Scans mit Hilfe der KI.
- **Excel**: Tabellen mit den Formeln neben den Werten (`3.6 (=B2*C2)`).
- **Scans und Fotos** liest die Texterkennung von macOS; Text in Bildern und Screenshots wird als `[Bildtext]` angehängt.
- **Bilder** stehen als Bilder in den .md-Dateien, dort wo sie im Original waren – aus PDFs genau ausgeschnitten,
  gescannte Seiten ganz. Du siehst sie in jedem Markdown-Programm (VS Code, Obsidian, Typora, GitHub); die Vorschau
  im Finder zeigt .md nur als Text. Claude sieht Bilder in einer .md-Datei nicht, es liest ihren erkannten Text –
  darum stehen in der Datei mit allem (`Mathematik.md`) keine Bildlinks, die kosten nur Tokens. Brauchst du ein Bild
  in Claude, lade es aus dem `… Bilder`-Ordner in den Chat.
- Kopf- und Fusszeilen, Seitenzahlen und Punkte im Inhaltsverzeichnis fliegen raus – die kosten nur Tokens.

## Die KI

Scriba liest zuerst ohne KI: Text aus PDFs, Word, PowerPoint und Excel ist schon sauber. Die KI räumt nur auf, wo es
hilft – Scans, Fotos, Screenshots und Formeln, die ein PDF zerrissen hat. Sie läuft **auf deinem Mac**:

- das Modell von Lotus (`lotus ai local`, z. B. Nucifera 20B),
- Apple Intelligence,
- oder Ollama.

Die KI darf nur abschreiben und aufräumen, nie rechnen oder ergänzen: Bringt ihre Antwort eine Zahl, die nicht im
erkannten Text steht, viele eigene Wörter oder lässt sie einen grossen Teil weg, bleibt der Text so, wie er gelesen
wurde – lieber unschön als falsch.

Ohne KI geht es auch – dann nur mit Texterkennung, schneller. Einstellen in `/scriba einstellungen`.

## Einstellungen

| | |
|---|---|
| Schulordner | der Ordner mit deinen Fächern (Scriba zeigt nur seinen Namen) |
| Ausgabe | wo die Texte landen – Standard: neben dem Schulordner |
| KI | Automatisch, das Modell auf dem Mac, Apple Intelligence, Ollama oder aus |
| KI liest | nur Scans, Bilder und Formeln (schnell) oder jede Seite (sauberer, langsam) |
| Bilder | zeigen (Standard) oder weglassen |
| Ausbildung, Lehrjahr | kommen in den Coach-Prompt |
| Neu umwandeln | alle Fächer noch einmal ganz |

## Was es liest

PDF (auch Scans) · Word (`.docx`, `.doc`, `.rtf`, `.odt`) · PowerPoint (`.pptx`, mit Notizen) · Excel (`.xlsx`) ·
Bilder (`.jpg`, `.png`, `.heic` …) · Jupyter-Notebooks · Text und Code (`.txt`, `.md`, `.java`, `.py`, `.html`,
`.css`, `.js`, `.sql`, `.cs` und mehr).

Videos, ZIP-Dateien und Pages/Keynote lässt es aus – exportiere Pages und Keynote als PDF.

## Der Coach-Prompt

[`prompt.md`](prompt.md) macht Claude zu deinem Prüfungscoach für die Lehre als Informatiker/in EFZ: erklärt Schritt
für Schritt, stellt immer genau eine offene Frage (nie Multiple Choice), bewertet deine Antwort und passt die
Schwierigkeit an. Er kennt das Format von Scriba und nennt dir die Fundstelle (`Bruchrechnen.pdf, S. 3`).
Befehle im Chat: **Start**, **Prüfungsmodus**, **Einfacher**, **Schwieriger**, **Wiederhole meine Schwächen**,
**Lernstand exportieren**, **Stopp**.

Deine Ausbildung und dein Lehrjahr stellst du in den Einstellungen ein – `p` setzt sie ein.

## Gut zu wissen

- Braucht macOS mit Lotus 2.16 oder neuer und einmal Apple's Command Line Tools (`xcode-select --install`) – die
  Texterkennung wird beim ersten Mal auf deinem Mac gebaut (etwa 20 Sekunden).
- Scriba ändert nie etwas in deinem Schulordner. Es liest nur und schreibt in den Ausgabeordner.
- Ctrl-C stoppt – was fertig ist, bleibt gespeichert.
- Schon mit Scriba 1.0 umgewandelt? «Neu umwandeln» in den Einstellungen holt die Bilder auch für diese Dateien.
- Neue Dateien zeigt dir Lotus auf dem Startbildschirm: «Scriba: 3 Dateien neu in Mathematik».

## Deinstallieren

```bash
lotus plugin uninstall scriba
```

Deine umgewandelten Texte bleiben, wo sie sind.

## Lizenz

MIT – siehe [LICENSE](LICENSE).
