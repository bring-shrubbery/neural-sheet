# Localization glossary

The fixed translations for NeuralSheet's German and Spanish (a11y and localization design §2,
[issue #25](https://github.com/bring-shrubbery/neural-sheet/issues/25)). Fixed first, so every
string that uses a term uses the same word; a translator or reviewer changes a term here before
changing it in the catalog.

The catalogs are `app/NeuralSheet/Localizable.xcstrings` (the app's strings, extracted by the
build), `Core.xcstrings` (the English names `NeuralSheetCore` gives — instruments, clefs, tunings,
undo titles — looked up at display time), `InfoPlist.xcstrings` and `AppShortcuts.xcstrings`.
Every key carries a comment saying where it is shown. `app/Scripts/check-localizations.sh` fails
on any unit without a translation.

The iPhone and iPad app ([issue #38](https://github.com/bring-shrubbery/neural-sheet/issues/38))
has its own `ios/NeuralSheet/Localizable.xcstrings` and `InfoPlist.xcstrings`, and
`ios/NeuralSheetWidgets/Localizable.xcstrings` for the Live Activity; it shares `Core.xcstrings`
by path. A target holds one `Localizable` table, and an iOS export would rewrite a shared Mac
file, so a string both apps show is in both catalogs: the check script fails when the iOS
catalog translates such a key differently from the Mac's. iOS's own words follow iOS's German
and Spanish, as the Mac's follow macOS's.

## Conventions

| | German | Spanish |
|---|---|---|
| Address | *du*, as macOS addresses its user | *tú*, as macOS does |
| Quotation marks | „…“ | “…” |
| Menu commands | Infinitive, as macOS: *Exportieren …* | Infinitive: *Exportar…* |
| Ellipsis | `…` after a space where the word is a noun phrase, as macOS German writes *Sichern unter …* | `…` with no space |
| Captions in capitals (TRANSCRIBE, MASTER) | In capitals | In capitals |
| Pitch names | Unchanged: C D E F G A B, ♯ and ♭, scientific octaves (C4). The roll, the score and the fields that parse them all use these. German *H* is not used, nor *B* or *Es* for B♭ and E♭: a transposition reads *B♭-Tenor (+14)* | Unchanged; *do re mi* is not used, except in the transpositions' names, as Spanish reads them (*Si♭ tenor*) |
| Key shortcuts in tooltips (`| Enter`, `(⌘U)`, `l`) | Unchanged | Unchanged |
| Units | dB, ms, s, BPM, GB, MB unchanged; numbers in the locale's own notation (`-3,0 dB`) | Unchanged units; locale notation |
| Tuning names | Proper names, unchanged: *Open G*, *Drop D*, *Double C*, *Low G*, *DADGAD*, *Chicago*, *Sawmill*; a descriptive name is translated (*Halbton tiefer*, *Irisch*) | The same: *Open G*, *Low G*; *Medio tono abajo*, *Irlandesa* |
| Status captions (TRANSCRIBING, SEPARATING, EXPORTING) | A noun: *TRANSKRIPTION*, *TRENNUNG*, *EXPORT*; in a row's status, *Wird transkribiert* | The gerund: *TRANSCRIBIENDO* |
| Product and format names | NeuralSheet, NeuralNote, MIDI, MusicXML, PDF, SoundFont, DLS, Demucs, Finder, Shortcuts, CoreAudio unchanged | Unchanged |
| The transport clock | `m:ss.dd` unchanged | Unchanged |

## Terms

| English | German | Spanish | Notes |
|---|---|---|---|
| take | Aufnahme | toma | The audio loaded or recorded |
| transcription | Transkription | transcripción | |
| transcribe | transkribieren | transcribir | |
| re-transcribe | neu transkribieren | retranscribir | |
| stems | Stems | stems | Not translated in either; *Stems* is a noun in German |
| separate (stems) | trennen | separar | |
| model | Modell | modelo | The transcription weights |
| instrument | Instrument | instrumento | |
| note | Note | nota | |
| velocity | Anschlagstärke | velocidad | As Logic Pro names it |
| pitch | Tonhöhe | altura | |
| pitch curve | Tonhöhenkurve | curva de altura | |
| confidence | Sicherheit | confianza | How sure the model was |
| grid | Raster | cuadrícula | |
| snap | einrasten | ajustar | Also Snap to Scale: *An Tonleiter einrasten* |
| quantize | quantisieren | cuantizar | |
| swing | Swing | swing | |
| division (of the grid) | Rasterteilung | división | |
| key (musical) | Tonart | tonalidad | |
| scale | Tonleiter | escala | |
| major / minor | Dur / Moll | mayor / menor | |
| tonic | Grundton | tónica | |
| tempo | Tempo | tempo | |
| tempo map | Tempokarte | mapa de tempo | |
| tempo change | Tempowechsel | cambio de tempo | |
| time signature, meter | Taktart | compás | |
| bar | Takt | compás | |
| beat | Schlag | pulso | |
| downbeat | Taktanfang | primer tiempo | |
| count-in | Einzähler | precuenta | Not *claqueta*, a clapperboard |
| click (metronome) | Klick | clic | |
| playhead | Abspielposition | cursor de reproducción | |
| ruler | Lineal | regla | |
| marker | Marker | marcador | |
| marked range | markierter Bereich | rango marcado | |
| loop (the Loop button) | Loop | loop | The loanword, as DAWs show it in both |
| tap (tempo) | Tap | Tap | The button; the tooltip says *tippen* / *pulsa* |
| speed (playback) | Geschwindigkeit; caption *GESCHW.* | velocidad; caption *VELOCIDAD* | The top bar's SPEED pill |
| piano roll | Pianorolle | piano roll | |
| keyboard (the key column) | Klaviatur | teclado | |
| waveform | Wellenform | forma de onda | |
| mix (ORIG / MIDI) | Mix | mezcla | |
| source audio | Originalaudio | audio original | |
| stereo split | Stereo-Split | división estéreo | |
| mute / solo | stummschalten / Solo | silenciar / solo | The strip's M and S stay M and S; the master panel's MUTE caption is *STUMM* / *SILENCIAR* |
| level | Pegel | nivel | |
| pan | Panorama | panorama | |
| output | Ausgang | salida | |
| input | Eingang | entrada | |
| sound bank | Klangbibliothek | banco de sonidos | |
| synth | Synthesizer | sintetizador | |
| score | Partitur | partitura | The Score tab |
| part | Stimme | parte | A part of the score |
| staff | Notensystem | pentagrama | |
| system (of staves) | Akkolade | sistema | |
| clef | Notenschlüssel | clave | |
| transposition | Transposition | transposición | |
| tab, tablature | Tabulatur | tablatura | |
| tuning | Stimmung | afinación | |
| string (of an instrument) | Saite | cuerda | |
| fret | Bund | traste | |
| chord | Akkord | acorde | |
| chord symbol | Akkordsymbol | cifrado | |
| root / quality / bass (of a chord) | Grundton / Typ / Bass | fundamental / tipo / bajo | |
| lyric, lyrics | Liedtext | letra | |
| syllable | Silbe | sílaba | |
| sheet (title block) | Notenblatt | hoja | |
| arranger | Arrangeur; credit *Arr.: %@* | arreglista; credit *arr. %@* | |
| version | Version | versión | |
| download | herunterladen | descargar | Not *laden*, which reads as *load* beside *konnte nicht geladen werden* |
| move (a note) | verschieben | mover | |
| project | Projekt | proyecto | |
| export / import | exportieren / importieren | exportar / importar | |
| batch | Stapel | lote | File → Batch Transcribe… |
| command-line tool | Befehlszeilenprogramm | herramienta de línea de comandos | |
| Settings | Einstellungen | Ajustes | The app's window; the system's is *Systemeinstellungen* / *Ajustes del Sistema* |
| tooltip | Tooltip | descripción emergente | |
| VoiceOver: note (role) | Note | nota | |
| note card | Notenkarte | ficha de la nota | The Mac's *Open Note Card*; on iOS a sheet or a popover |
| part card | Stimmenkarte | ficha de la parte | |
| Share… (iOS) | Teilen … | Compartir… | The system's share sheet |
| Save to Files… (iOS) | In „Dateien“ sichern … | Guardar en Archivos… | As iOS names the Files app in each |
| Files, Photos (the iOS apps) | Dateien, Fotos | Archivos, Fotos | |
| Live Activity (iOS) | Live-Aktivität | Actividad en directo | The Lock Screen and Dynamic Island card |
| fallback tone (iOS) | Ersatzklang | tono de reserva | The synth's own sound with no sound bank |
| roll (the iOS tab) | Pianorolle | Piano roll | The tab and screen with the piano roll |
| strips (the iOS mixer) | Instrumente | instrumentos | Shown as *Instruments*; not translated as a technical term |

## Reviewing

A reviewer reads each translated unit against its English and its comment, checks the format
specifiers (`%@`, `%lld`, positional `%1$@`) are all there, that a plural has every form the
language needs (German *one* and *other*, Spanish *one*, *many* and *other*), and that a caption
fits where it is shown: the tab strip, the toolbar's buttons and the strip's meta line have no
room to wrap.
